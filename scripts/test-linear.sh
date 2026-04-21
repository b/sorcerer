#!/usr/bin/env bash
# Exercise the Linear MCP write path: resolve the configured team, create a
# test issue, read it back, and cancel it. Confirms sorcerer can write to
# Linear via the MCP tools (not via raw GraphQL).
#
# Reads default_team_key from config.json. Spawns a headless `claude -p`
# session that follows prompts/test-linear.md and reports a final
# TEST_PASSED / TEST_FAILED line; this script parses the marker and sets
# the exit code accordingly.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.shell_env"
fi

CONFIG="${SORCERER_CONFIG:-$REPO_ROOT/config.json}"
PROMPT_TEMPLATE="$REPO_ROOT/prompts/test-linear.md"

[[ -f "$CONFIG" ]]          || { echo "ERROR: config file not found at $CONFIG" >&2; exit 1; }
[[ -f "$PROMPT_TEMPLATE" ]] || { echo "ERROR: prompt template not found at $PROMPT_TEMPLATE" >&2; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI required" >&2; exit 1; }

TEAM_KEY=$(jq -r '.linear.default_team_key // ""' "$CONFIG")
if [[ -z "$TEAM_KEY" ]]; then
  echo "ERROR: linear.default_team_key not set in $CONFIG" >&2
  exit 1
fi

PROMPT="$(sed "s/__TEAM_KEY__/$TEAM_KEY/g" "$PROMPT_TEMPLATE")"

echo "=== Linear MCP self-test (team=$TEAM_KEY) ==="
echo

OUTPUT=$(
  claude -p \
    --output-format text \
    --permission-mode bypassPermissions \
    "$PROMPT" \
  2>&1
)
RC=$?
echo "$OUTPUT"
echo

if grep -qE '^TEST_PASSED' <<<"$OUTPUT"; then
  echo "=== RESULT: PASS ==="
  exit 0
elif grep -qE '^TEST_FAILED' <<<"$OUTPUT"; then
  echo "=== RESULT: FAIL ==="
  exit 1
else
  echo "=== RESULT: INCONCLUSIVE (no TEST_PASSED/TEST_FAILED line; claude exit=$RC) ==="
  exit "${RC:-2}"
fi
