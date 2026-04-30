#!/usr/bin/env bash
# render-tick-context.sh
#
# Writes .sorcerer/.tick-context.md — a compact, LLM-readable digest of:
#   - tick mode classification result
#   - coordinator pause state
#   - per-provider state (active vs throttled-until)
#   - non-terminal architects (with id, status, started_at, paths)
#   - non-terminal wizards   (with id, mode, status, started_at, lineage,
#                             issue/branch/PR refs as applicable)
#   - pending requests (post-drain — should normally be 0)
#   - last 8 events
#   - escalations from the last 7 days (capped to 10 most recent)
#
# This replaces the LLM tick's habit of `Read .sorcerer/sorcerer.json` —
# which on long-lived projects is dominated by terminal-state history
# (merged wizards, completed/archived architects) that doesn't inform any
# current decision. The digest preserves only what the tick actually needs.
#
# Usage:
#   scripts/render-tick-context.sh [project_root]
#
# Side effects:
#   - Writes .sorcerer/.tick-context.md (atomic via tmp+rename).
#
# Exit: 0 on success. 0 (with no file) if .sorcerer/sorcerer.json is missing.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

OUT=".sorcerer/.tick-context.md"
STATE=".sorcerer/sorcerer.json"

[[ -f "$STATE" ]] || exit 0

NON_TERMINAL_STATUSES='[
  "pending-architect","running","throttled",
  "awaiting-architect-review","architect-review-running",
  "awaiting-tier-2","awaiting-design-review","design-review-running",
  "awaiting-tier-3","awaiting-review","merging"
]'

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mode=$(cat .sorcerer/.tick-mode 2>/dev/null || echo "unknown")

tmp=$(mktemp)
{
  echo "# Sorcerer state digest"
  echo
  echo "Rendered at \`$now\` by \`scripts/render-tick-context.sh\`."
  echo
  echo "**This digest is the canonical state input for the tick.** Read it before falling back to \`.sorcerer/sorcerer.json\`. The raw JSON is still authoritative for fields not surfaced here (full PR-set state for step 12, worktree paths, throttle counts, etc.) — read it directly only when the digest doesn't carry the field you need."
  echo
  echo "## Tick mode"
  echo
  echo "- \`$mode\`"
  echo

  echo "## Coordinator + provider state"
  echo
  paused=$(jq -r '.paused_until // "none"' "$STATE")
  echo "- paused_until: \`$paused\`"
  echo "- providers:"
  jq -r '
    (.providers_state // {})
    | to_entries
    | sort_by(.key)
    | if length == 0 then "  (no providers configured — ambient auth)"
      else map(
        if (.value.throttled_until // null) == null then
          "  - \(.key): active"
        else
          "  - \(.key): throttled until \(.value.throttled_until) (count=\(.value.throttle_count // 0))"
        end
      ) | join("\n")
      end
  ' "$STATE"
  echo

  echo "## Active architects (non-terminal)"
  echo
  arch_n=$(jq --argjson terms "$NON_TERMINAL_STATUSES" '
    (.active_architects // []) | map(select(.status as $s | $terms | index($s))) | length
  ' "$STATE")
  if [[ "$arch_n" == "0" ]]; then
    echo "(none)"
  else
    jq -r --argjson terms "$NON_TERMINAL_STATUSES" '
      (.active_architects // [])
      | map(select(.status as $s | $terms | index($s)))
      | map(
          "- id=\(.id)"
          + " status=\(.status)"
          + " started=\(.started_at)"
          + (if .pid != null then " pid=\(.pid)" else "" end)
          + (if (.respawn_count // 0) > 0 then " respawns=\(.respawn_count)" else "" end)
          + (if .review_wizard_id != null then " review_wizard=\(.review_wizard_id)" else "" end)
          + (if .retry_after != null then " retry_after=\(.retry_after)" else "" end)
          + "\n  request: \(.request_file // "none")"
          + "\n  plan:    \(.plan_file // "(not yet written)")"
        )
      | join("\n")
    ' "$STATE"
  fi
  echo

  echo "## Active wizards (non-terminal)"
  echo
  wiz_n=$(jq --argjson terms "$NON_TERMINAL_STATUSES" '
    (.active_wizards // []) | map(select(.status as $s | $terms | index($s))) | length
  ' "$STATE")
  if [[ "$wiz_n" == "0" ]]; then
    echo "(none)"
  else
    jq -r --argjson terms "$NON_TERMINAL_STATUSES" '
      (.active_wizards // [])
      | map(select(.status as $s | $terms | index($s)))
      | map(
          "- id=\(.id) mode=\(.mode) status=\(.status) started=\(.started_at)"
          + (if .pid != null then " pid=\(.pid)" else "" end)
          + (if (.respawn_count // 0) > 0 then " respawns=\(.respawn_count)" else "" end)
          + (if .retry_after != null then " retry_after=\(.retry_after)" else "" end)
          + (if .architect_id != null then "\n  architect_id=\(.architect_id)" else "" end)
          + (if .sub_epic_name != null then " sub_epic=\"\(.sub_epic_name)\"" else "" end)
          + (if .epic_linear_id != null then " epic=\(.epic_linear_id)" else "" end)
          + (if .designer_id != null then "\n  designer_id=\(.designer_id)" else "" end)
          + (if .issue_key != null then " issue=\(.issue_key)" else "" end)
          + (if .branch_name != null then " branch=\(.branch_name)" else "" end)
          + (if .subject_id != null then "\n  subject=\(.subject_id) (kind=\(.subject_kind // "?"))" else "" end)
          + (if .review_decision != null then " decision=\(.review_decision)" else "" end)
          + (if (.refer_back_cycle // 0) > 0 then " refer_back=\(.refer_back_cycle)" else "" end)
          + (if (.conflict_cycle // 0) > 0 then " conflict_cycle=\(.conflict_cycle)" else "" end)
          + (if (.orphan_adopted // false) then " (orphan-adopted)" else "" end)
        )
      | join("\n")
    ' "$STATE"
  fi
  echo

  echo "## Pending requests (post-drain)"
  echo
  if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
    ls -1 .sorcerer/requests/*.md | sed 's/^/- /'
  else
    echo "(none — pre-tick step 3 already drained any to architects/<id>/request.md)"
  fi
  echo

  echo "## Recent events (last 8)"
  echo
  if [[ -f .sorcerer/events.log ]]; then
    tail -8 .sorcerer/events.log | sed 's/^/- /'
  else
    echo "(no events log yet)"
  fi
  echo

  echo "## Recent escalations (last 7d)"
  echo
  if [[ -f .sorcerer/escalations.log && -s .sorcerer/escalations.log ]]; then
    cutoff=$(date -u -d "7 days ago" +%s)
    recent=$(awk -v cutoff="$cutoff" '
      {
        if (match($0, /"ts":"[^"]+"/)) {
          ts_field = substr($0, RSTART+6, RLENGTH-7)
          cmd = "date -u -d \"" ts_field "\" +%s 2>/dev/null"
          if ((cmd | getline e) > 0 && e >= cutoff) print
          close(cmd)
        }
      }
    ' .sorcerer/escalations.log | tail -10)
    if [[ -n "$recent" ]]; then
      printf '%s\n' "$recent" | sed 's/^/- /'
    else
      echo "(none in last 7d)"
    fi
  else
    echo "(none)"
  fi
} > "$tmp"
mv "$tmp" "$OUT"
exit 0
