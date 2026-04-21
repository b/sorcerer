#!/usr/bin/env bash
# The sorcerer coordinator loop.
#
# Runs the tick prompt repeatedly via `claude -p` until there is no pending
# work in state/sorcerer.yaml, then exits cleanly. /sorcerer re-spawns this
# loop (via start-coordinator.sh) when new requests arrive.
#
# Pending work = a file in state/requests/, OR an active_architect with status
# `pending-architect` or `running`, OR an active_wizard with `pending-design`,
# `running`, or any other in-flight status. Tier-2/Tier-3 statuses will be
# added here as those modes ship.
#
# Sleep interval: 30s when there is in-flight work, 60s when only awaiting-
# tier-2 entries remain (waiting for the next request → no point ticking
# fast, but we shouldn't exit since hand-off may come soon).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.shell_env"
fi

PID_FILE="$REPO_ROOT/state/coordinator.pid"
TICK_PROMPT_FILE="$REPO_ROOT/prompts/sorcerer-tick.md"

[[ -f "$TICK_PROMPT_FILE" ]] || { echo "ERROR: missing $TICK_PROMPT_FILE" >&2; exit 1; }
TICK_PROMPT="$(cat "$TICK_PROMPT_FILE")"

# Always remove the pid file on exit so start-coordinator.sh can spawn a fresh loop next time.
trap 'rm -f "$PID_FILE"' EXIT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

has_in_flight_work() {
  # Returns 0 (true) if there is anything actively progressing OR queued.
  # Includes awaiting-tier-2 (architect deferred designer spawn) and
  # awaiting-tier-3 (designer awaiting implement spawn) because the next
  # tick may need to pick them up. Excludes awaiting-review because slice
  # 9 (PR review automation) hasn't shipped — once all implements are
  # awaiting-review the loop should exit and let the user review/merge.
  if compgen -G "state/requests/*.md" > /dev/null 2>&1; then
    return 0
  fi
  if [[ -f state/sorcerer.yaml ]] && grep -qE 'status: (pending-architect|running|awaiting-tier-2|awaiting-tier-3|pending-design)' state/sorcerer.yaml; then
    return 0
  fi
  return 1
}

echo "[$(ts)] coordinator-loop started (pid $$)"

while true; do
  if ! has_in_flight_work; then
    echo "[$(ts)] no in-flight work; exiting"
    exit 0
  fi

  echo "[$(ts)] running tick"
  if ! claude -p \
      --output-format text \
      --permission-mode bypassPermissions \
      --max-budget-usd 2 \
      --model claude-sonnet-4-6 \
      "$TICK_PROMPT" \
      < /dev/null; then
    echo "[$(ts)] tick exited non-zero"
  fi

  # Sleep interval: 30s when actively running something, 60s otherwise.
  if [[ -f state/sorcerer.yaml ]] && grep -qE 'status: running' state/sorcerer.yaml; then
    sleep 30
  else
    sleep 60
  fi
done
