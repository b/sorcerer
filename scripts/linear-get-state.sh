#!/usr/bin/env bash
# Fetch a Linear issue's current state name via a thin Haiku-backed
# `claude -p` call that uses the mcp__plugin_linear_linear__get_issue
# tool. Used by post-tick.sh's reconciliation sweep (step 13) to detect
# Linear-Done drift on already-merged wizards.
#
# Usage:
#   scripts/linear-get-state.sh <issue_id_or_key>
#
# Args:
#   issue_id_or_key  Linear issue UUID or key (e.g. "SOR-446").
#
# Output (last line of stdout): one of
#   - The exact state name as Linear reports it (e.g. "Done", "In Progress")
#   - "unknown"  — Linear MCP unreachable or any failure
# Exit: always 0.
#
# Cost: one short Haiku call per invocation (one Linear MCP read).
set -euo pipefail

ISSUE="${1:?usage: $0 <issue_id_or_key>}"

emit() { printf '%s\n' "$1"; exit 0; }

PROMPT=$(cat <<EOF
Use the mcp__plugin_linear_linear__get_issue tool with id: "$ISSUE".

The response contains a "status" field with the issue's current state name (e.g. "Done", "In Progress", "In Review", "Backlog", "Todo", "Cancelled").

Output ONLY the state name as a single line. No prose, no quotes, no JSON, no code fences.

If the call fails for any reason (Linear MCP needs-auth, network error, plugin not loaded, issue not found), output exactly: unknown
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
[[ -z "$RESULT" ]] && RESULT=$(ask)
[[ -z "$RESULT" ]] && RESULT="unknown"
emit "$RESULT"
