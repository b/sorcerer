#!/usr/bin/env bash
# backfill-linear-projects.sh
#
# One-shot migration: associate every existing project-labeled issue
# in Linear with the umbrella project recorded in
# `.sorcerer/config.json:linear.project_uuid`. Used once per project
# at the moment the umbrella project is introduced.
#
# Run this AFTER `scripts/ensure-linear-project.sh` has populated
# `linear.project_uuid` in config.json (i.e. after the umbrella project
# exists in Linear). Pre-tick runs ensure-linear-project on every tick;
# the simplest path is: run pre-tick once, verify project_uuid is set,
# then run this.
#
# Idempotent at the per-issue level: setting an issue's project to a
# value it already holds is a no-op on Linear's side.
#
# Usage:
#   scripts/backfill-linear-projects.sh [project_root]
#
# Requires:
#   - .sorcerer/config.json with linear.default_team_key,
#     linear.project_label, AND linear.project_uuid all set.
#   - Linear MCP available.
#
# Cost: one Haiku-backed claude -p invocation that does the full scan
# + per-issue project-set loop in a single call. ~$0.05 per 100 issues.
#
# Exit: 0 on success. Non-zero on config / MCP failure.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

CONFIG=.sorcerer/config.json
[[ -f "$CONFIG" ]] || { echo "ERROR: missing $CONFIG" >&2; exit 1; }

TEAM=$(jq -r '.linear.default_team_key // empty' "$CONFIG")
LABEL=$(jq -r '.linear.project_label // empty' "$CONFIG")
UUID=$(jq -r '.linear.project_uuid // empty' "$CONFIG")

[[ -n "$LABEL" ]] || LABEL=$(basename "$PROJECT_ROOT")

if [[ -z "$TEAM" ]]; then
  echo "ERROR: linear.default_team_key not set in $CONFIG" >&2
  exit 1
fi
if [[ -z "$UUID" ]]; then
  echo "ERROR: linear.project_uuid not set in $CONFIG" >&2
  echo "       Run scripts/ensure-linear-project.sh first to create the umbrella project." >&2
  exit 1
fi

[[ -f .sorcerer/.token-env ]] && source .sorcerer/.token-env

cat <<EOF
backfill-linear-projects: starting one-shot migration
  team:           $TEAM
  project label:  $LABEL
  umbrella UUID:  $UUID

This script will:
  1. List all non-completed, non-cancelled issues in team $TEAM
     carrying label "$LABEL".
  2. For each issue whose projectId is NOT "$UUID", call save_issue
     with project="$UUID" to associate it with the umbrella.
  3. Print a summary: already-associated / newly-associated / failed.

EOF
read -r -p "Proceed? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "aborted"; exit 0 ;;
esac

PROMPT=$(cat <<EOF
Backfill the umbrella Linear project (UUID "$UUID") onto every non-terminal issue in team "$TEAM" that carries label "$LABEL". Procedure:

1. Use mcp__plugin_linear_linear__list_issues with team="$TEAM", label="$LABEL", limit=250, includeArchived=false. Loop through pages with the cursor parameter until exhausted.

2. Filter the result locally to issues whose statusType is NOT "completed" and NOT "canceled".

3. For each remaining issue, examine its projectId. If projectId equals "$UUID", count it as "already-associated" and continue.

4. Otherwise call mcp__plugin_linear_linear__save_issue with id=<issue.identifier>, project="$UUID". Track count as "newly-associated" on success or "failed" on error.

5. After the loop, print exactly one line of output:
   BACKFILL: already=<N>, associated=<N>, failed=<N>

If the Linear MCP is unavailable for any reason, print:
   BACKFILL_FAILED: <reason>

Output ONLY one of those two lines. No prose, no JSON, no explanation, no code fences.
EOF
)

echo "running backfill (this may take several minutes)..."
result=$(claude -p \
  --output-format text \
  --permission-mode bypassPermissions \
  --model claude-haiku-4-5 \
  "$PROMPT" </dev/null 2>&1 \
  | tr -d '\r' \
  | awk 'NF' \
  | tail -1)

echo
echo "result: $result"
case "$result" in
  BACKFILL:*) exit 0 ;;
  *)          exit 2 ;;
esac
