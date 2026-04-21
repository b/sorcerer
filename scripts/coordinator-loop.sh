#!/usr/bin/env bash
# The sorcerer coordinator loop — runs per project.
#
# Usage: scripts/coordinator-loop.sh <project-root>
#
# Runs the tick prompt repeatedly via `claude -p` in the project's directory
# until there is no pending work in <project>/.sorcerer/sorcerer.yaml, then
# exits cleanly. /sorcerer re-spawns this loop (via start-coordinator.sh) when
# new requests arrive.
#
# Pending work = a file in .sorcerer/requests/, OR an active entry in
# .sorcerer/sorcerer.yaml with an in-flight status.
set -uo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }
cd "$PROJECT_ROOT"

if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.shell_env"
fi

PID_FILE="$PROJECT_ROOT/.sorcerer/coordinator.pid"
TICK_PROMPT_FILE="$SORCERER_REPO/prompts/sorcerer-tick.md"

[[ -f "$TICK_PROMPT_FILE" ]] || { echo "ERROR: missing $TICK_PROMPT_FILE" >&2; exit 1; }
TICK_PROMPT="$(cat "$TICK_PROMPT_FILE")"

trap 'rm -f "$PID_FILE"' EXIT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

has_in_flight_work() {
  # See docs/lifecycle.md for the status taxonomy. The loop keeps running as
  # long as any entry is in a non-terminal state.
  if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
    return 0
  fi
  if [[ -f .sorcerer/sorcerer.yaml ]] && grep -qE 'status: (pending-architect|running|awaiting-tier-2|awaiting-tier-3|pending-design|awaiting-review|merging)' .sorcerer/sorcerer.yaml; then
    return 0
  fi
  return 1
}

echo "[$(ts)] coordinator-loop started (pid $$) for $PROJECT_ROOT"

while true; do
  if ! has_in_flight_work; then
    echo "[$(ts)] no in-flight work; exiting"
    exit 0
  fi

  echo "[$(ts)] running tick"
  # No --model: use whatever claude's default is (currently opus). The tick
  # does real judgment work — state-machine routing, PR-set review, failure
  # classification — so we want the stronger model by default. If an operator
  # wants to downgrade for cost, they can edit .sorcerer/config.yaml and we'll
  # honor it in a future slice that reads models.coordinator at tick time.
  if ! claude -p \
      --output-format text \
      --permission-mode bypassPermissions \
      "$TICK_PROMPT" \
      < /dev/null; then
    echo "[$(ts)] tick exited non-zero"
  fi

  # Pacing: 30s while anything is actively running, 60s otherwise.
  if [[ -f .sorcerer/sorcerer.yaml ]] && grep -qE 'status: running' .sorcerer/sorcerer.yaml; then
    sleep 30
  else
    sleep 60
  fi
done
