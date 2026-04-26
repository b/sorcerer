#!/usr/bin/env bash
# Start the coordinator loop for a project, if not already running. Idempotent.
#
# Usage: scripts/start-coordinator.sh <project-root>
#
# The coordinator is a detached bash process running scripts/coordinator-loop.sh
# with the project root as its first arg. It runs the tick prompt repeatedly via
# `claude -p` until there is no pending work in <project>/.sorcerer/sorcerer.json,
# then exits cleanly. /sorcerer re-spawns it whenever a new request arrives.
#
# Pre-flight: refuses to start if ANY coordinator-loop.sh process for this
# project-root is already alive (registered or orphan). Run stop-coordinator.sh
# (or restart-coordinator.sh) first to clear orphans; otherwise a fresh loop
# would race the survivors and split-brain on the next tick.
#
# Exit codes:
#   0 — coordinator already running, OR fresh loop started
#   1 — bad argument (project root not a directory)
#   2 — orphan coordinator-loop processes detected; refusing to start
set -euo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-coordinator-procs.sh
source "$SCRIPT_DIR/lib-coordinator-procs.sh"

STATE="$PROJECT_ROOT/.sorcerer"
PID_FILE="$STATE/coordinator.pid"
LOG_FILE="$STATE/coordinator.log"
mkdir -p "$STATE"

# Idempotent fast-path: if the registered pid is alive, we're already running.
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Coordinator already running (pid $pid) for $PROJECT_ROOT"
    exit 0
  fi
  # stale pid file; fall through after the orphan check
  rm -f "$PID_FILE"
fi

# Orphan check: any coordinator-loop.sh for this project root that is NOT the
# registered pid (which we just confirmed is dead/absent) is an orphan that
# must be cleaned up before we add another loop on top of it.
mapfile -t orphans < <(find_coordinator_loops "$PROJECT_ROOT")
if [[ "${#orphans[@]}" -gt 0 ]]; then
  echo "ERROR: ${#orphans[@]} orphan coordinator-loop process(es) for $PROJECT_ROOT: ${orphans[*]}" >&2
  echo "       Run scripts/stop-coordinator.sh '$PROJECT_ROOT' first (or scripts/restart-coordinator.sh)." >&2
  exit 2
fi

nohup bash "$SORCERER_REPO/scripts/coordinator-loop.sh" "$PROJECT_ROOT" >> "$LOG_FILE" 2>&1 &
new_pid=$!
echo "$new_pid" > "$PID_FILE"
echo "Coordinator started (pid $new_pid) for $PROJECT_ROOT"
