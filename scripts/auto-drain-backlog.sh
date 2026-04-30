#!/usr/bin/env bash
# auto-drain-backlog.sh
#
# When pre-tick has classified the upcoming tick as `idle` (no in-flight
# architects, no in-flight wizards, no pending operator requests, no
# new escalations) but `scripts/has-linear-work.sh` reports unclaimed
# non-terminal SOR issues remaining in Linear, auto-file a sorcerer
# drain request so the next tick spawns an architect to decompose the
# remaining backlog.
#
# Without this, an idle coordinator with backlog left in Linear would
# either (a) skip ticks indefinitely without making progress, or
# (b) require an operator to manually `/sorcerer <prompt>` to kick
# things off again. The user's contract: only stop when there's no
# pending prompt AND nothing in the backlog.
#
# Rate-limited via .sorcerer/.last-auto-drain — does not auto-file more
# than once per SORCERER_AUTO_DRAIN_COOLDOWN_SEC (default 1800s / 30m)
# to prevent a wedged-architect loop from hammering the request dir.
#
# Side effects (only on auto-file):
#   - Writes .sorcerer/requests/<ts>-auto-drain-backlog.md
#   - Touches .sorcerer/.last-auto-drain
#
# This script does NOT drain the request itself — that's pre-tick's
# step 3. Pre-tick re-runs its drain logic after invoking this script
# so any auto-filed request gets converted to a pending-architect
# entry on the SAME tick (no wasted 6-minute idle skip).
#
# Usage:
#   scripts/auto-drain-backlog.sh [project_root]
#
# Exit: 0 always. Prints a one-line status to stdout describing what
# happened (skipped due to mode, skipped due to cooldown, skipped due
# to existing request, Linear-says-no, Linear-unknown, or filed).
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
COOLDOWN="${SORCERER_AUTO_DRAIN_COOLDOWN_SEC:-1800}"

cd "$PROJECT_ROOT"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Only fire on idle ticks. Defensive default: if .tick-mode is missing,
# don't auto-drain (mechanical/recovery/creative all imply work is
# happening; pre-#86 deployments without a classifier should keep their
# old behavior unchanged).
mode=$(cat .sorcerer/.tick-mode 2>/dev/null || echo unknown)
if [[ "$mode" != "idle" ]]; then
  echo "tick mode is '$mode' (not idle); skipping"
  exit 0
fi

# Don't file if a request is already pending (defensive — pre-tick's
# step 3 should have drained anything pre-existing, so a non-empty
# requests/ dir here means another auto-drain or operator-submit is
# active).
if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
  echo "request directory non-empty; skipping"
  exit 0
fi

# Rate limit.
marker=.sorcerer/.last-auto-drain
last_epoch=$(stat -c %Y "$marker" 2>/dev/null || echo 0)
now_epoch=$(date +%s)
if (( now_epoch - last_epoch < COOLDOWN )); then
  remain=$(( COOLDOWN - (now_epoch - last_epoch) ))
  printf 'cooldown active (%dm%02ds remaining); skipping\n' \
    $((remain/60)) $((remain%60))
  exit 0
fi

# Check Linear for unclaimed work. has-linear-work.sh is cached by the
# coordinator-loop in a separate cache file but we re-call it here —
# the call is cheap (one Haiku call when not cached, ~0s when cached
# via has-linear-work's internal mechanisms) and safer than reading a
# stale cache the loop might not have refreshed.
if [[ ! -x "$SORCERER_REPO/scripts/has-linear-work.sh" ]]; then
  echo "has-linear-work.sh not executable at $SORCERER_REPO/scripts/; skipping"
  exit 0
fi

has_work=$(bash "$SORCERER_REPO/scripts/has-linear-work.sh" "$PROJECT_ROOT" 2>/dev/null | tail -1 || echo unknown)
case "$has_work" in
  yes)
    : # proceed to auto-file below
    ;;
  no)
    echo "Linear says no unclaimed work; coordinator-loop will exit on next iteration"
    exit 0
    ;;
  *)
    echo "Linear check returned '$has_work'; skipping (next tick will retry)"
    exit 0
    ;;
esac

# File the auto-drain request.
slug=$(date -u +%Y%m%dT%H%M%SZ)
req=".sorcerer/requests/${slug}-auto-drain-backlog.md"
mkdir -p .sorcerer/requests
cat > "$req" <<EOF
# Auto-drain Linear backlog (filed by sorcerer auto-drain at $(ts))

The coordinator is otherwise idle (no in-flight architects, no in-flight wizards, no pending operator requests, no new escalations) but \`scripts/has-linear-work.sh\` reports unclaimed non-terminal SOR issues remaining in the Linear backlog.

Decompose the remaining backlog into a fresh architect plan and ship it. Apply the standard architect rules — survey \`docs/rust-rewrite/ABSENT_FUNCTIONALITY.md\` and any prior architect plans on disk to avoid re-decomposing already-shipped work, prioritize Urgent (P1) and High (P2) issues, and bound sub-epic count by what can land in a reasonable session.

This request was auto-filed by \`scripts/auto-drain-backlog.sh\` and is rate-limited to ~once per ${COOLDOWN}s to prevent loops; if it appears repeatedly without backlog draining an operator should investigate.
EOF

# Touch the rate-limit marker AFTER successfully writing the request
# so a partial-write (request file failed to land) doesn't skip the
# next legitimate auto-drain.
touch "$marker"

echo "filed $req"
exit 0
