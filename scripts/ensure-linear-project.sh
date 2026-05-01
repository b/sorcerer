#!/usr/bin/env bash
# ensure-linear-project.sh
#
# Idempotently ensure the umbrella Linear project for this sorcerer-project
# exists in the configured team. The umbrella project's name defaults to
# basename(project_root) (e.g. `archers` for /home/b/.../archers); every
# sorcerer-created Linear issue gets its `projectId` set to the umbrella's
# UUID, so all of the project's work rolls up under a single Linear
# project in the UI — without per-sub-epic project explosion AND without
# needing a separate label for disambiguation.
#
# On first run, creates the project and writes its UUID back to
# `.sorcerer/config.json:linear.project_uuid`. On subsequent runs,
# short-circuits via the .sorcerer/.linear-project-ok marker.
#
# Usage:
#   scripts/ensure-linear-project.sh [project_root]
#
# Side effects:
#   - On first success: creates a Linear project, writes its UUID to
#     `.sorcerer/config.json:linear.project_uuid`, touches
#     `.sorcerer/.linear-project-ok` with the (team:label:uuid) tuple.
#   - On subsequent runs (marker exists with matching team:label): no-op.
#
# Exit: 0 on success or any tolerable failure (Linear MCP unavailable,
# etc.). Never blocks the tick.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

CONFIG=.sorcerer/config.json
MARKER=.sorcerer/.linear-project-ok

[[ -f "$CONFIG" ]] || { echo "no $CONFIG; skipping"; exit 0; }

TEAM=$(jq -r '.linear.default_team_key // empty' "$CONFIG")
EXISTING_UUID=$(jq -r '.linear.project_uuid // empty' "$CONFIG")

# Project name defaults to basename(project_root). Sorcerer doesn't store
# a separate project_name field — the umbrella project's name is the
# project root's basename, period. Operators who want a different display
# name can rename the project in Linear's UI; the UUID stays stable.
PROJECT_NAME=$(basename "$PROJECT_ROOT")

if [[ -z "$TEAM" ]]; then
  echo "no linear.default_team_key in config; skipping"
  exit 0
fi

# Idempotency short-circuit: marker matches (team, label, uuid) and config
# carries a uuid — nothing to do.
if [[ -f "$MARKER" && -n "$EXISTING_UUID" ]]; then
  prev=$(cat "$MARKER" 2>/dev/null || echo "")
  if [[ "$prev" == "${TEAM}:${PROJECT_NAME}:${EXISTING_UUID}" ]]; then
    exit 0
  fi
fi

[[ -f .sorcerer/.token-env ]] && source .sorcerer/.token-env

PROMPT=$(cat <<EOF
Ensure a Linear umbrella project named "$PROJECT_NAME" exists in team "$TEAM".

1. Resolve the team UUID: call mcp__plugin_linear_linear__get_team with query="$TEAM". Capture team.id.
2. Look for an existing project: call mcp__plugin_linear_linear__list_projects with team="$TEAM", limit=250. Find the project whose name equals "$PROJECT_NAME" exactly (case-sensitive). If found, capture its id.
3. If no matching project exists, create one: call mcp__plugin_linear_linear__save_project with name="$PROJECT_NAME", description="Umbrella Linear project for sorcerer-managed work in the $PROJECT_NAME project. All sorcerer-created issues for this project use this project's UUID for grouping.", team=<team UUID from step 1>. Capture the response's id field.
4. Print exactly one line, the project's id (UUID, e.g. abc123-...). No prose, no JSON, no code fences.

If the Linear MCP is unavailable for any reason, print "unknown" on its own line and stop.
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

# Validate the response looks like a UUID (very loose: dashed hex).
if [[ "$RESULT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  uuid="$RESULT"
  # Persist into config.json under linear.project_uuid (atomic via tmp+mv).
  tmp=$(mktemp)
  jq --arg uuid "$uuid" '.linear.project_uuid = $uuid' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  printf '%s' "${TEAM}:${PROJECT_NAME}:${uuid}" > "$MARKER"
  echo "umbrella project '$PROJECT_NAME' ready (uuid=$uuid)"
else
  echo "Linear MCP returned '$RESULT'; will retry next tick"
fi
exit 0
