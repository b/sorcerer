#!/usr/bin/env bash
# Spawn a blind second-opinion reviewer for a PR set whose first review
# decided `merge`. Returns the second reviewer's JSON verdict on stdout.
#
# Usage: scripts/second-opinion-review.sh \
#          --issue-key SOR-N \
#          --issue-linear-id <uuid> \
#          --pr-urls '<JSON object: {"owner/repo":"<url>", ...}>' \
#          --branch-name <branch> \
#          --repos '<JSON array of github.com/owner/repo>' \
#          [--project-root <dir>]
#
# Picks the first non-throttled provider that's NOT the one the caller
# (coord tick) is currently using, when possible — this maximizes
# independence (different account → different rate-limit history → harder
# for systemic bias to align). Falls back to the same provider when no
# alternative is healthy.
#
# Exits 0 with the JSON line on stdout when the reviewer produces output.
# Exits 1 (no stdout) on missing args, MCP unavailability, or claude -p
# failure — the caller treats failure-to-second-opinion as "skip second
# opinion this tick" rather than escalating, since a hung second opinion
# would block every merge.
set -uo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

ISSUE_KEY=""
ISSUE_LINEAR_ID=""
PR_URLS_JSON=""
BRANCH_NAME=""
REPOS_JSON=""
PROJECT_ROOT="$(pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue-key)        ISSUE_KEY="$2"; shift 2 ;;
    --issue-linear-id)  ISSUE_LINEAR_ID="$2"; shift 2 ;;
    --pr-urls)          PR_URLS_JSON="$2"; shift 2 ;;
    --branch-name)      BRANCH_NAME="$2"; shift 2 ;;
    --repos)            REPOS_JSON="$2"; shift 2 ;;
    --project-root)     PROJECT_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

for var in ISSUE_KEY ISSUE_LINEAR_ID PR_URLS_JSON BRANCH_NAME REPOS_JSON; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: --${var,,} required" >&2
    exit 1
  fi
done

cd "$PROJECT_ROOT" || { echo "ERROR: cannot cd to $PROJECT_ROOT" >&2; exit 1; }

PROMPT_FILE="$SORCERER_REPO/prompts/second-opinion-review.md"
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: missing $PROMPT_FILE" >&2; exit 1; }

# Pick a provider that's NOT the current SORCERER_ACTIVE_PROVIDER, when
# possible. We re-source apply-provider-env.sh in a subshell with the
# already-active provider added to a "skip" list to make the lookup
# straightforward.
CURRENT="${SORCERER_ACTIVE_PROVIDER:-}"
PICKED=""
PICKED_TOKEN=""

if [[ -f .sorcerer/config.json ]]; then
  while IFS= read -r prov; do
    [[ -z "$prov" ]] && continue
    [[ "$prov" == "$CURRENT" ]] && continue
    # Throttled?
    until_iso=""
    if [[ -f .sorcerer/sorcerer.json ]]; then
      until_iso=$(jq -r --arg n "$prov" \
        '(.providers_state[$n].throttled_until // "")' .sorcerer/sorcerer.json 2>/dev/null)
    fi
    now_epoch=$(date +%s)
    if [[ -n "$until_iso" ]]; then
      t_epoch=$(date -d "$until_iso" +%s 2>/dev/null || echo 0)
      (( t_epoch > now_epoch )) && continue
    fi
    PICKED="$prov"
    break
  done < <(jq -r '(.providers // [])[].name' .sorcerer/config.json)
fi

# Fall back to the current provider if no alternative is healthy.
[[ -z "$PICKED" ]] && PICKED="$CURRENT"

# Apply the picked provider's env in a subshell-friendly form.
if [[ -n "$PICKED" && -f "$SORCERER_REPO/scripts/apply-provider-env.sh" ]]; then
  # Force-target the picked provider by writing a synthetic state file the
  # apply script will honor: clear other providers' throttled_until so the
  # selector lands on PICKED first. Simpler: re-implement the per-provider
  # env extraction inline here.
  while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    if [[ "$v" =~ ^\$\{(.+)\}$ ]]; then
      varname="${BASH_REMATCH[1]}"
      v="${!varname:-}"
    fi
    export "$k=$v"
  done < <(jq -r --arg p "$PICKED" '
    (.providers // [])[] | select(.name == $p) | (.env // {}) | to_entries[] |
    "\(.key)\t\(.value)"
  ' .sorcerer/config.json 2>/dev/null)
fi

# Build the input block.
INPUTS=$(jq -nc \
  --arg issue_key "$ISSUE_KEY" \
  --arg issue_linear_id "$ISSUE_LINEAR_ID" \
  --argjson pr_urls "$PR_URLS_JSON" \
  --arg branch_name "$BRANCH_NAME" \
  --argjson repos "$REPOS_JSON" \
  '{issue_key:$issue_key, issue_linear_id:$issue_linear_id, pr_urls:$pr_urls, branch_name:$branch_name, repos:$repos}'
)

PROMPT_BODY=$(cat "$PROMPT_FILE")
FULL_PROMPT="$PROMPT_BODY

<inputs>
$INPUTS
</inputs>"

# Run the second reviewer. Read-only by default — no bypassPermissions. The
# prompt itself instructs the reviewer not to write; the permission default
# is the belt to the suspenders.
TICK_ARGS=(--output-format text)
# Inherit model + effort from config.json's reviewer entry, falling back to
# coordinator's choices if reviewer-specific aren't set.
if [[ -f .sorcerer/config.json ]]; then
  m=$(jq -r '(.models.reviewer // .models.coordinator // "")' .sorcerer/config.json 2>/dev/null)
  e=$(jq -r '(.effort.reviewer // .effort.coordinator // "")' .sorcerer/config.json 2>/dev/null)
  [[ -n "$m" && "$m" != "null" ]] && TICK_ARGS+=(--model "$m")
  [[ -n "$e" && "$e" != "null" ]] && TICK_ARGS+=(--effort "$e")
fi

# 25-minute hard cap — second opinion is a single review pass; if it's not
# done in 25m something's wrong and the caller is better off skipping than
# blocking the tick.
out=$(timeout 1500 claude -p "${TICK_ARGS[@]}" "$FULL_PROMPT" < /dev/null 2>&1) || {
  echo "ERROR: second-opinion claude -p failed (rc=$?, last 20 lines below)" >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 1
}

# Extract the JSON object — last `{...}` block in the output. The reviewer
# prompt asks for "exactly one JSON object" but be forgiving of trailing
# whitespace / accidental prose.
json=$(printf '%s\n' "$out" | awk '
  /^\s*\{/ { in_json=1; buf="" }
  in_json   { buf = buf $0 "\n" }
  /^\s*\}/  { if (in_json) { last=buf; in_json=0 } }
  END       { if (last != "") print last }
')

if [[ -z "$json" ]] || ! jq -e . <<<"$json" >/dev/null 2>&1; then
  echo "ERROR: second-opinion produced no parseable JSON object" >&2
  printf '%s\n' "$out" | tail -30 >&2
  exit 1
fi

printf '%s\n' "$json"
