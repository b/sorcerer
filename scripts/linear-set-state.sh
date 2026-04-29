#!/usr/bin/env bash
# Set a Linear issue's state via a thin Haiku-backed `claude -p` call that
# uses the mcp__plugin_linear_linear__save_issue tool. Used by post-tick.sh
# step 13 (cleanup merged issues) to push status → Done.
#
# Usage:
#   scripts/linear-set-state.sh <issue_id_or_key> <state>
#
# Args:
#   issue_id_or_key  Linear issue UUID or key (e.g. "SOR-446").
#   state            Linear state name (e.g. "Done", "In Progress").
#
# Output (last line of stdout): "ok" | "error" | "unknown"
# Exit: always 0. Errors surface as "error" / "unknown" in stdout.
#
# Cost: one ~10s Haiku call per invocation (one Linear MCP write).
set -euo pipefail

ISSUE="${1:?usage: $0 <issue_id_or_key> <state>}"
STATE="${2:?usage: $0 <issue_id_or_key> <state>}"

emit() { printf '%s\n' "$1"; exit 0; }

PROMPT=$(cat <<EOF
Use the mcp__plugin_linear_linear__save_issue tool with these arguments:
  id: "$ISSUE"
  state: "$STATE"

If the call succeeds (the tool returns an issue object whose status now matches "$STATE", or an idempotent no-op success when the issue was already in that state), output exactly: ok

If the call fails for any reason — Linear MCP needs-auth, network error, plugin not loaded, permission denied, issue not found, invalid state — output exactly: error

If you cannot determine which case applies, output exactly: unknown

Output ONLY one of those three exact words on its own line. No prose, no JSON, no code fences.
EOF
)

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

RESULT=$(ask) || RESULT=""
if [[ "$RESULT" != "ok" && "$RESULT" != "error" ]]; then
  RESULT=$(ask) || RESULT=""
fi

case "$RESULT" in
  ok|error|unknown) emit "$RESULT" ;;
  *)                emit "unknown" ;;
esac
