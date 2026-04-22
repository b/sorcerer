#!/usr/bin/env bash
# The sorcerer coordinator loop — runs per project.
#
# Usage: scripts/coordinator-loop.sh <project-root>
#
# Runs the tick prompt repeatedly via `claude -p` in the project's directory
# until there is no pending work in <project>/.sorcerer/sorcerer.json, then
# exits cleanly. /sorcerer re-spawns this loop (via start-coordinator.sh) when
# new requests arrive.
#
# Pending work = a file in .sorcerer/requests/, OR an active entry in
# .sorcerer/sorcerer.json with an in-flight status.
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
  if [[ -f .sorcerer/sorcerer.json ]] && jq -e '
      def entries: (.active_architects // []) + (.active_wizards // []);
      [entries[].status] | any(
        . == "pending-architect" or
        . == "running"           or
        . == "throttled"         or
        . == "awaiting-tier-2"   or
        . == "awaiting-tier-3"   or
        . == "pending-design"    or
        . == "awaiting-review"   or
        . == "merging"
      )' .sorcerer/sorcerer.json > /dev/null 2>&1; then
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

  # Honor a global pause set by the tick when too many rate-limit (429) errors
  # pile up. paused_until is an ISO-8601 timestamp; we sleep in 30s chunks so
  # a newly-arrived request or user Ctrl-C still gets noticed promptly.
  if [[ -f .sorcerer/sorcerer.json ]]; then
    paused_until=$(jq -r '.paused_until // ""' .sorcerer/sorcerer.json 2>/dev/null || echo "")
    if [[ -n "$paused_until" ]]; then
      now_epoch=$(date +%s)
      pause_epoch=$(date -d "$paused_until" +%s 2>/dev/null || echo 0)
      if (( pause_epoch > now_epoch )); then
        remain=$(( pause_epoch - now_epoch ))
        echo "[$(ts)] coordinator paused until $paused_until ($remain s remaining); sleeping"
        sleep $(( remain < 30 ? remain : 30 ))
        continue
      fi
    fi
  fi

  echo "[$(ts)] running tick"
  # Apply config.json:models.coordinator / effort.coordinator if set. Both
  # default to claude's own defaults when absent, so an unconfigured project
  # keeps working; an operator who wants a specific model or downgraded
  # effort edits .sorcerer/config.json.
  TICK_ARGS=(--output-format text --permission-mode bypassPermissions)
  if [[ -f .sorcerer/config.json ]]; then
    tick_model=$(jq -r '.models.coordinator // ""' .sorcerer/config.json 2>/dev/null || echo "")
    tick_effort=$(jq -r '.effort.coordinator // ""' .sorcerer/config.json 2>/dev/null || echo "")
    [[ -n "$tick_model"  ]] && TICK_ARGS+=(--model  "$tick_model")
    [[ -n "$tick_effort" ]] && TICK_ARGS+=(--effort "$tick_effort")
  fi
  if ! claude -p "${TICK_ARGS[@]}" "$TICK_PROMPT" < /dev/null; then
    echo "[$(ts)] tick exited non-zero"
  fi

  # Pacing: 30s while anything is actively running, 60s otherwise.
  if [[ -f .sorcerer/sorcerer.json ]] && jq -e '
      def entries: (.active_architects // []) + (.active_wizards // []);
      [entries[].status] | any(. == "running")
    ' .sorcerer/sorcerer.json > /dev/null 2>&1; then
    sleep 30
  else
    sleep 60
  fi
done
