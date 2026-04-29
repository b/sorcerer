#!/usr/bin/env bash
# Answer: does Linear have any non-terminal issues for the project's team
# that are NOT already claimed by an active_architects / active_wizards
# entry in sorcerer.json?
#
# Used by coordinator-loop.sh's has_in_flight_work() as a "last chance"
# check: when sorcerer.json's primary signal returns no in-flight work,
# the loop calls this to decide whether there's Linear-side backlog the
# next tick should drain (via step 7's orphan-issue sweeper, or operator
# follow-up). Without this check, the coordinator exits the moment its
# in-memory state empties, and the Backlog never gets pulled in.
#
# Output (last line of stdout): "yes" | "no" | "unknown"
# Exit code: always 0 (errors surface as "unknown" in stdout, never as
# a non-zero exit — callers parse stdout, not $?).
#
# Cost: spawns one `claude -p` with Linear MCP. ~10–30s + a small token
# bill per call. Coordinator-loop callers should cache the result for a
# few minutes to avoid burning a query every tick.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

emit() { printf '%s\n' "$1"; exit 0; }

if [[ ! -f .sorcerer/config.json ]]; then
  emit "unknown"
fi

TEAM=$(jq -r '.linear.default_team_key // empty' .sorcerer/config.json)
[[ -n "$TEAM" ]] || emit "unknown"

# Linear UUIDs already claimed by some live entry. issue_linear_id is the
# canonical identifier on implement / feedback / rebase wizards. Architect
# / designer entries don't carry it directly — their plan.json / manifest
# does — but once a designer fans out, each child implement wizard carries
# the linear_id, so the union below converges quickly. A few ticks of
# "Linear says yes, but the issues are about to be claimed" is a tolerable
# false positive; it just keeps the coordinator alive briefly.
CLAIMED_JSON='[]'
if [[ -f .sorcerer/sorcerer.json ]]; then
  CLAIMED_JSON=$(jq -c '
    ((.active_architects // []) + (.active_wizards // []))
    | map(.issue_linear_id // empty)
    | unique
  ' .sorcerer/sorcerer.json 2>/dev/null || echo '[]')
fi

# Source the App token cache so the spawned claude inherits the same
# GitHub auth context as the coordinator. Linear MCP itself uses
# Anthropic-side OAuth, not this token, but other tools the prompt might
# touch (none today, but the door is open) need it.
[[ -f .sorcerer/.token-env ]] && source .sorcerer/.token-env

PROMPT=$(cat <<EOF
Use the mcp__plugin_linear_linear__list_issues tool with these arguments:
  team: "$TEAM"
  limit: 250
  includeArchived: false

Filter the result to issues whose statusType is NOT "completed" and NOT "canceled" — i.e., any issue still in Backlog, Todo, In Progress, In Review, Blocked, or any other non-terminal state.

Compare each remaining issue's id (the Linear UUID) against this set of already-claimed UUIDs:

$CLAIMED_JSON

Decision rule:
- If at least one non-terminal issue's id is NOT in the claimed set, the answer is "yes".
- If every non-terminal issue's id IS in the claimed set (or the non-terminal set is empty), the answer is "no".
- If the Linear MCP call fails for any reason (auth, network, plugin missing, tool unavailable), the answer is "unknown".

Output ONLY one of these three exact words on its own line: yes / no / unknown
No prose, no JSON, no explanation, no code fences.
EOF
)

# Cap each call at 90s. A yes/no question against a 250-issue list
# should return in well under that; if claude is taking longer, the
# result is almost certainly stuck and we'd rather treat it as unknown.
ask() {
  timeout 90 claude -p \
    --output-format text \
    --permission-mode bypassPermissions \
    --model claude-haiku-4-5 \
    "$PROMPT" </dev/null 2>/dev/null \
  | tr -d '\r' \
  | awk 'NF' \
  | tail -1
}

# Single retry on "unknown" — observed in practice: the plugin-namespaced
# Linear MCP tool sometimes isn't visible to a freshly-spawned claude on
# the first call (plugin marketplace load race). A second attempt typically
# succeeds. The cost (one extra Haiku call on miss) is cheap relative to
# a wrongly-exited coordinator that drops the Backlog.
RESULT=$(ask) || RESULT=""
if [[ "$RESULT" != "yes" && "$RESULT" != "no" ]]; then
  RESULT=$(ask) || RESULT=""
fi

case "$RESULT" in
  yes|no|unknown) emit "$RESULT" ;;
  *)              emit "unknown" ;;
esac
