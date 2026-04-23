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
# Selection rule: strict primary → fallback. Iterate `config.providers` in
# order and pick the first entry whose `providers_state[name].throttled_until`
# is either null, missing, or in the past. If every provider is throttled,
# SORCERER_ACTIVE_PROVIDER is left empty and the caller should NOT attempt the
# claude -p call (the tick handles this by setting `paused_until` at the
# coordinator level; coordinator-loop.sh already honors that).
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

# Walk providers in order; first non-throttled wins.
while IFS= read -r _name; do
  [[ -z "$_name" ]] && continue

  _throttled_until=""
  if [[ -f "$_state" ]]; then
    _throttled_until=$(jq -r --arg n "$_name" '(.providers_state[$n].throttled_until // "")' "$_state" 2>/dev/null || echo "")
  fi

  if [[ -n "$_throttled_until" ]]; then
    _t_epoch=$(date -d "$_throttled_until" +%s 2>/dev/null || echo 0)
    if (( _t_epoch > _now_epoch )); then
      continue  # still cooling down
    fi
  fi

  SORCERER_ACTIVE_PROVIDER="$_name"
  break
done < <(jq -r '(.providers // [])[].name' "$_cfg")

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
