#!/usr/bin/env bash
# Pick the active sorcerer provider and export its env vars.
#
# Usage:
#   source scripts/apply-provider-env.sh [<config.json>] [<sorcerer.json>]
#
# Both arguments default to `.sorcerer/config.json` and `.sorcerer/sorcerer.json`
# relative to the caller's cwd. The caller MUST source (not exec) this so the
# exported vars survive into the subsequent claude -p invocation.
#
# After sourcing, three shell variables are set:
#   SORCERER_ACTIVE_PROVIDER   name of the provider, or "" when config has no providers
#   SORCERER_PROVIDER_MODELS   JSON object of per-role model overrides, or "{}"
#   SORCERER_PROVIDER_REASON   short human-readable explanation (for logs)
#
# Selection rule (slice 62): round-robin among non-throttled providers.
# Strict primary→fallback (the prior rule) concentrates load on the first
# provider until it hits the weekly limit, then on the second, etc. With
# four Max accounts, that's the worst possible shape — one account burns
# its weekly ceiling while three sit idle. Round-robin spreads load: each
# spawn advances a cursor in `.sorcerer/last-provider` to the next
# non-throttled provider, wrapping at the end. Effective per-account load
# becomes 1/N of total, pushing the weekly ceiling N× further.
#
# Cursor file format: a single line containing the provider name last
# picked. Created on first use. Lives in the project's .sorcerer/ — each
# project rotates independently. Concurrent callers (multiple wizards
# sourcing this script in the same tick) coordinate via flock on the
# cursor file so no two callers pick the same provider in a race.
#
# When EVERY provider is throttled, SORCERER_ACTIVE_PROVIDER is left empty
# (same as before) and the caller should NOT attempt the claude -p call.
# The tick handles this by setting `paused_until` at the coordinator level.
#
# Env var expansion: a value of `${NAME}` in a provider's `env` map expands to
# the caller's current value of `$NAME`. Literal values are exported verbatim.
# This keeps secrets in `~/.shell_env` (or wherever the caller sources them
# from) rather than in `config.json`.

set -uo pipefail

_cfg="${1:-.sorcerer/config.json}"
_state="${2:-.sorcerer/sorcerer.json}"

SORCERER_ACTIVE_PROVIDER=""
SORCERER_PROVIDER_MODELS="{}"
SORCERER_PROVIDER_REASON=""

if [[ ! -f "$_cfg" ]]; then
  SORCERER_PROVIDER_REASON="no config at $_cfg"
  return 0 2>/dev/null || exit 0
fi

# No providers array, or empty array → nothing to do (backward-compatible
# with pre-provider configs; the caller uses whatever ambient env is set).
_provider_count=$(jq -r '(.providers // []) | length' "$_cfg" 2>/dev/null || echo 0)
if [[ "$_provider_count" == "0" ]]; then
  SORCERER_PROVIDER_REASON="no providers configured"
  return 0 2>/dev/null || exit 0
fi

_now_epoch=$(date +%s)

# Round-robin selection (slice 62). Read the cursor (last-picked provider
# name); start the scan one position past the cursor; wrap modulo the
# provider count; pick the first non-throttled. If the cursor names a
# provider no longer in config (added/removed across coord restarts),
# treat as if the cursor were unset (start at index 0).
_cursor_file="$(dirname "$_state")/last-provider"
_cursor=""
if [[ -f "$_cursor_file" ]]; then
  _cursor=$(cat "$_cursor_file" 2>/dev/null || echo "")
fi

# Build the providers[].name array as a bash array.
_provider_names=()
while IFS= read -r _n; do
  [[ -z "$_n" ]] && continue
  _provider_names+=("$_n")
done < <(jq -r '(.providers // [])[].name' "$_cfg")

_n_total="${#_provider_names[@]}"
[[ "$_n_total" -gt 0 ]] || { return 0 2>/dev/null || exit 0; }

# Find cursor's index. If the cursor names a removed provider, _cursor_idx
# stays -1 and the next-pos formula starts at 0.
_cursor_idx=-1
for ((_i = 0; _i < _n_total; _i++)); do
  if [[ "${_provider_names[$_i]}" == "$_cursor" ]]; then
    _cursor_idx="$_i"
    break
  fi
done

# Walk up to N positions starting just past the cursor.
_picked_idx=-1
for ((_step = 1; _step <= _n_total; _step++)); do
  _try_idx=$(( (_cursor_idx + _step) % _n_total ))
  _try_name="${_provider_names[$_try_idx]}"

  _throttled_until=""
  if [[ -f "$_state" ]]; then
    _throttled_until=$(jq -r --arg n "$_try_name" '(.providers_state[$n].throttled_until // "")' "$_state" 2>/dev/null || echo "")
  fi
  if [[ -n "$_throttled_until" ]]; then
    _t_epoch=$(date -d "$_throttled_until" +%s 2>/dev/null || echo 0)
    if (( _t_epoch > _now_epoch )); then
      continue   # this provider still cooling down; try the next
    fi
  fi

  SORCERER_ACTIVE_PROVIDER="$_try_name"
  _picked_idx="$_try_idx"
  break
done

# Persist the new cursor under flock so concurrent callers (multiple
# wizards sourcing this script in the same tick) advance through the
# rotation cleanly without two of them picking the same provider.
if [[ "$_picked_idx" -ge 0 ]]; then
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 9
      printf '%s\n' "$SORCERER_ACTIVE_PROVIDER" > "$_cursor_file"
    ) 9>"${_cursor_file}.lock"
  else
    printf '%s\n' "$SORCERER_ACTIVE_PROVIDER" > "$_cursor_file"
  fi
fi

if [[ -z "$SORCERER_ACTIVE_PROVIDER" ]]; then
  SORCERER_PROVIDER_REASON="all providers throttled"
  return 0 2>/dev/null || exit 0
fi

# Apply env map: expand ${NAME} values from the caller's environment.
while IFS=$'\t' read -r _k _v; do
  [[ -z "$_k" ]] && continue
  if [[ "$_v" =~ ^\$\{(.+)\}$ ]]; then
    _varname="${BASH_REMATCH[1]}"
    _v="${!_varname:-}"
  fi
  export "$_k=$_v"
done < <(jq -r --arg p "$SORCERER_ACTIVE_PROVIDER" '
  (.providers // [])[] | select(.name == $p) | (.env // {}) | to_entries[] |
  "\(.key)\t\(.value)"
' "$_cfg")

# Per-provider model override map (may be empty). Caller's per-role model
# resolution should prefer this over top-level .models.<role>.
SORCERER_PROVIDER_MODELS=$(jq -rc --arg p "$SORCERER_ACTIVE_PROVIDER" '
  (.providers // [])[] | select(.name == $p) | (.models // {})
' "$_cfg" 2>/dev/null || echo "{}")

SORCERER_PROVIDER_REASON="selected $SORCERER_ACTIVE_PROVIDER"
