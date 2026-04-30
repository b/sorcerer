#!/usr/bin/env bash
# classify-tick-mode.sh
#
# Reads .sorcerer/sorcerer.json + .sorcerer/escalations.log + .sorcerer/requests/
# and writes .sorcerer/.tick-mode with one of:
#
#   idle        — no in-flight architects/wizards, no pending requests, no
#                 new escalations since last tick. The LLM tick can be
#                 skipped entirely.
#   mechanical  — in-flight work exists but no creative LLM work needed
#                 (no awaiting-review wizard, no failed entries, no new
#                 escalations). Run the LLM tick normally.
#   creative    — at least one wizard is in awaiting-review (step 12 PR
#                 review is genuinely LLM-bound creative work).
#   recovery    — a failed architect/wizard or a new escalation needs
#                 routing. Always run the LLM.
#
# Used by coordinator-loop.sh to decide whether to skip the claude -p tick
# entirely. Idle skips are bounded by SORCERER_MAX_IDLE_SKIPS (default 5)
# consecutive skips; after that, the next tick is forced to mechanical so
# periodic LLM-side sweeps (step 7 standalone-issue catcher, step 11d
# orphan-PR adoption) eventually fire.
#
# Usage:
#   scripts/classify-tick-mode.sh [project_root]
#
# Args:
#   project_root  Path to project root (default: $PWD).
#
# Side effects:
#   - Writes .sorcerer/.tick-mode (single word, no newline-trailing checks).
#   - Tracks .sorcerer/.idle-skip-count (int, bumped on each idle classify).
#   - Tracks .sorcerer/.escalations-size (int, byte size of escalations.log
#     at last classification — used to detect new entries).
#
# Exit: 0 always. On error reading state, defaults to writing "mechanical"
# so the safe behavior is "run the LLM" (no behavior change vs. pre-slice).
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

MAX_IDLE_SKIPS="${SORCERER_MAX_IDLE_SKIPS:-5}"
MODE_FILE=".sorcerer/.tick-mode"
SKIP_FILE=".sorcerer/.idle-skip-count"
ESC_SIZE_FILE=".sorcerer/.escalations-size"
ESC_LOG=".sorcerer/escalations.log"
STATE=".sorcerer/sorcerer.json"

# Defensive default: if state is unreadable, run the LLM (no regression).
if [[ ! -f "$STATE" ]]; then
  printf 'mechanical' > "$MODE_FILE"
  exit 0
fi

# Statuses that mean "this entry is still doing work" — anything not in this
# list is terminal (completed / merged / failed / archived / blocked / null).
# `failed` and `blocked` go through the recovery branch instead.
NON_TERMINAL_STATUSES='[
  "pending-architect","running","throttled",
  "awaiting-architect-review","architect-review-running",
  "awaiting-tier-2","awaiting-design-review","design-review-running",
  "awaiting-tier-3","awaiting-review","merging"
]'

set_mode() {
  printf '%s' "$1" > "$MODE_FILE"
  case "$1" in
    idle) ;;  # idle bumps skip counter elsewhere
    *)   rm -f "$SKIP_FILE" ;;  # any non-idle resets the bound
  esac
}

# Always update the escalations baseline first, before any classification
# branch can short-circuit. The baseline must stay in sync with the log
# regardless of which mode we end up writing — otherwise a single recovery
# classification could leave the baseline stale and make every subsequent
# call misread "no growth" as "new escalations".
new_escalations=0
if [[ -f "$ESC_LOG" ]]; then
  cur_size=$(stat -c %s "$ESC_LOG" 2>/dev/null || echo 0)
  prev_size=$(cat "$ESC_SIZE_FILE" 2>/dev/null || echo 0)
  if (( cur_size > prev_size )); then
    new_escalations=1
  fi
  printf '%s' "$cur_size" > "$ESC_SIZE_FILE"
fi

# ---------- recovery: failed/blocked entries OR new escalations ----------
# Stale `failed` / `blocked` entries that haven't been archived yet pin
# recovery mode, which is fine — the LLM tick should clean them up. Idle
# skips activate once the active_wizards list is clean.
failed_count=$(jq '
  ((.active_architects // []) + (.active_wizards // []))
  | map(select(.status == "failed" or .status == "blocked"))
  | length
' "$STATE" 2>/dev/null || echo 0)
if (( failed_count > 0 || new_escalations )); then
  set_mode recovery
  exit 0
fi

# ---------- creative: awaiting-review wizard exists ----------
awaiting_review=$(jq '
  (.active_wizards // [])
  | map(select(.status == "awaiting-review"))
  | length
' "$STATE" 2>/dev/null || echo 0)
if (( awaiting_review > 0 )); then
  set_mode creative
  exit 0
fi

# ---------- mechanical: any non-terminal entry, or any pending request ----------
non_terminal=$(jq --argjson terms "$NON_TERMINAL_STATUSES" '
  ((.active_architects // []) + (.active_wizards // []))
  | map(select(.status as $s | $terms | index($s)))
  | length
' "$STATE" 2>/dev/null || echo 0)

pending_requests=0
if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
  pending_requests=$(ls -1 .sorcerer/requests/*.md 2>/dev/null | wc -l)
fi

if (( non_terminal > 0 || pending_requests > 0 )); then
  set_mode mechanical
  exit 0
fi

# ---------- idle (bounded) ----------
# After MAX_IDLE_SKIPS consecutive idle classifications, force a mechanical
# tick so periodic LLM-side sweeps (step 7, step 11d) eventually fire.
skip_count=$(cat "$SKIP_FILE" 2>/dev/null || echo 0)
if (( skip_count >= MAX_IDLE_SKIPS )); then
  set_mode mechanical  # also clears SKIP_FILE
  exit 0
fi

printf 'idle' > "$MODE_FILE"
printf '%s' $((skip_count + 1)) > "$SKIP_FILE"
exit 0
