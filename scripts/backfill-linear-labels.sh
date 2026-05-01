#!/usr/bin/env bash
# backfill-linear-labels.sh
#
# One-shot migration: adds the project label to every existing
# non-completed/non-cancelled Linear issue in the configured team.
# Used once per project at the moment project_label is introduced —
# all currently open issues in the team are assumed to belong to this
# project (true for the archers cutover; if you're running this for
# a project where some open issues belong to OTHER projects, do not
# use this script — tag them by hand or with a project-specific
# filter).
#
# Idempotent at the per-issue level: save_issue with `labels` REPLACES
# the label set, so this script first reads each issue's current
# labels via get_issue, appends the project label if missing, and
# writes the union back. Already-labeled issues are no-ops.
#
# Usage:
#   scripts/backfill-linear-labels.sh [project_root]
#
# Requires:
#   - .sorcerer/config.json with linear.default_team_key and
#     linear.project_label set (or project_label derivable from
#     basename($PROJECT_ROOT))
#   - Linear MCP available
#   - The label itself must already exist in the team — run
#     scripts/ensure-linear-label.sh first if needed.
#
# Cost: one Haiku-backed claude -p invocation that does the full
# scan + per-issue read+write loop in one shot. Roughly $0.05 per 100
# issues at current Haiku pricing. Slow but reliable; designed to run
# once and never again for a given project.
#
# Exit: 0 on success. Non-zero on config/MCP failure.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

CONFIG=.sorcerer/config.json
[[ -f "$CONFIG" ]] || { echo "ERROR: missing $CONFIG" >&2; exit 1; }

TEAM=$(jq -r '.linear.default_team_key // empty' "$CONFIG")
LABEL=$(jq -r '.linear.project_label // empty' "$CONFIG")
[[ -n "$LABEL" ]] || LABEL=$(basename "$PROJECT_ROOT")

if [[ -z "$TEAM" ]]; then
  echo "ERROR: linear.default_team_key not set in $CONFIG" >&2
  exit 1
fi

[[ -f .sorcerer/.token-env ]] && source .sorcerer/.token-env

cat <<EOF
backfill-linear-labels: starting one-shot migration
  team:  $TEAM
  label: $LABEL

This script will:
  1. List all non-completed, non-cancelled issues in team $TEAM.
  2. For each issue WITHOUT label "$LABEL", add it (preserving
     existing labels via read+merge+write).
  3. Print a summary of touched / skipped / failed counts.

EOF
read -r -p "Proceed? [y/N] " confirm
case "$confirm" in
  y|Y|yes|YES) ;;
  *) echo "aborted"; exit 0 ;;
esac

PROMPT=$(cat <<EOF
Backfill the project label "$LABEL" onto every non-terminal issue in Linear team "$TEAM" that doesn't already carry it. Procedure:

1. Use mcp__plugin_linear_linear__list_issues with team="$TEAM", limit=250, includeArchived=false. Loop through pages with the cursor parameter until exhausted.

2. Filter the result locally to issues whose statusType is NOT "completed" and NOT "canceled".

3. For each remaining issue, examine its labels. If "$LABEL" is already present, count it as "already-labeled" and continue.

4. Otherwise call mcp__plugin_linear_linear__get_issue with id=<issue.identifier> to get the full label set (the list_issues view may not include it — verify with get_issue).

5. Compute new_labels = existing_labels ∪ {"$LABEL"}. Call mcp__plugin_linear_linear__save_issue with id=<issue.identifier>, labels=new_labels. (Linear's save_issue REPLACES the label set, so passing the union is required to preserve existing labels.)

6. Track counts in three categories: already_labeled, newly_tagged, failed.

7. After the loop, print exactly one line of output:
   BACKFILL: already=<N>, tagged=<N>, failed=<N>

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
