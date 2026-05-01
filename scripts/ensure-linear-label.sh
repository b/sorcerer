#!/usr/bin/env bash
# ensure-linear-label.sh
#
# Idempotently ensure the project's Linear label exists in the configured
# team. Called from pre-tick.sh so that all downstream Linear writes
# (designer creating issues, backfill script tagging old issues) and
# downstream Linear reads (has-linear-work, step 7 sweeper, design-review
# consistency) can rely on the label being present.
#
# The label name comes from config.json:linear.project_label, falling
# back to basename(project_root) when unset. The team comes from
# config.json:linear.default_team_key.
#
# Usage:
#   scripts/ensure-linear-label.sh [project_root]
#
# Side effects:
#   - On first run for a project: creates the label in Linear via MCP.
#   - Writes .sorcerer/.linear-label-ok marker on success so subsequent
#     ticks short-circuit without burning a Linear call.
#   - Logs a one-line status to stdout.
#
# Exit: 0 on success or any tolerable failure (label not yet creatable
# because Linear MCP isn't ready, etc.). Never blocks the tick.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

CONFIG=.sorcerer/config.json
MARKER=.sorcerer/.linear-label-ok

# No-op if config is missing — caller (pre-tick) hasn't bootstrapped yet.
[[ -f "$CONFIG" ]] || { echo "ensure-linear-label: no $CONFIG; skipping"; exit 0; }

TEAM=$(jq -r '.linear.default_team_key // empty' "$CONFIG")
LABEL=$(jq -r '.linear.project_label // empty' "$CONFIG")

# Default project_label to basename(project_root) when unset.
if [[ -z "$LABEL" ]]; then
  LABEL=$(basename "$PROJECT_ROOT")
fi

if [[ -z "$TEAM" ]]; then
  echo "ensure-linear-label: no linear.default_team_key in config; skipping"
  exit 0
fi

# Idempotency short-circuit: if the marker exists AND records the same
# (team, label) we ensured before, no Linear call needed.
if [[ -f "$MARKER" ]]; then
  prev=$(cat "$MARKER" 2>/dev/null || echo "")
  if [[ "$prev" == "${TEAM}:${LABEL}" ]]; then
    exit 0
  fi
fi

[[ -f .sorcerer/.token-env ]] && source .sorcerer/.token-env

PROMPT=$(cat <<EOF
Ensure a Linear label named "$LABEL" exists in team "$TEAM".

1. Call mcp__plugin_linear_linear__list_issue_labels with team="$TEAM" and name="$LABEL".
2. If the response contains a label with name exactly "$LABEL", print "exists" on its own line and stop.
3. Otherwise, call mcp__plugin_linear_linear__create_issue_label with name="$LABEL" and any reasonable color (e.g. "#5E6AD2"). Pass the team UUID as teamId — resolve it first via mcp__plugin_linear_linear__get_team query="$TEAM".
4. After successful creation, print "created" on its own line and stop.

If the Linear MCP is unavailable for any reason, print "unknown" on its own line and stop.

Output ONLY one of these three exact words on its own line: exists / created / unknown
No prose, no JSON, no explanation, no code fences.
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
case "$RESULT" in
  exists|created)
    printf '%s' "${TEAM}:${LABEL}" > "$MARKER"
    echo "ensure-linear-label: label '$LABEL' $RESULT in team $TEAM"
    ;;
  *)
    echo "ensure-linear-label: Linear MCP returned '$RESULT' (will retry next tick)"
    ;;
esac
exit 0
