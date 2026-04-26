#!/usr/bin/env bash
# Stop the coordinator loop for a project, if running.
#
# Usage: scripts/stop-coordinator.sh <project-root>
#
# Sends SIGTERM to the registered pid, waits up to 10s, escalates to SIGKILL if
# needed. Then runs a survivor sweep: enumerates ALL `coordinator-loop.sh`
# processes whose first arg matches THIS project-root literally and kills any
# survivors (SIGTERM + 5s + SIGKILL each). Removes the pid file regardless of
# how the process exits. Does not stop in-flight wizard sessions (they run as
# independent detached processes).
#
# The sweep exists because `coordinator-loop.sh` spawns sub-bash subshells per
# tick; SIGKILL on the registered parent reparents children to init (PPID=1),
# where they continue as orphan loops and split-brain the next tick (see
# escalations.log entries with rule:split-brain-coordinators).
#
# Exit codes:
#   0 — no coordinator-loop processes for this project remain
#   1 — bad argument (project root not a directory)
#   2 — survivors still alive after the sweep (operator must investigate)
set -uo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-coordinator-procs.sh
source "$SCRIPT_DIR/lib-coordinator-procs.sh"

PID_FILE="$PROJECT_ROOT/.sorcerer/coordinator.pid"

# kill_with_timeout <pid> [<wait-seconds>]
# SIGTERM, poll until <wait-seconds> elapse, then SIGKILL. Returns immediately
# if the pid is already gone.
kill_with_timeout() {
  local pid="$1" wait_s="${2:-5}" i
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  for ((i = 0; i < wait_s; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
  # Poll briefly for the kernel to reap the SIGKILL'd process; without this,
  # an immediate `kill -0` from the caller can race the kernel and falsely
  # report the process as still alive (init auto-reaps reparented children
  # within milliseconds, but "milliseconds" is non-zero).
  for ((i = 0; i < 10; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
}

# Step 1 — handle the registered pid (best-effort).
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Stopping coordinator (pid $pid) for $PROJECT_ROOT..."
    kill_with_timeout "$pid" 10
    if kill -0 "$pid" 2>/dev/null; then
      echo "Registered coordinator $pid did not exit even after SIGKILL" >&2
    else
      echo "Registered coordinator $pid stopped"
    fi
  else
    echo "Registered pid '$pid' not running (stale or absent)"
  fi
  rm -f "$PID_FILE"
else
  echo "No pid file at $PID_FILE"
fi

# Step 2 — survivor sweep. Two attempts: first SIGTERMs everything in parallel,
# second pass catches anything that needed SIGKILL by sweeping again.
for attempt in 1 2; do
  mapfile -t survivors < <(find_coordinator_loops "$PROJECT_ROOT")
  [[ "${#survivors[@]}" -eq 0 ]] && break
  echo "Sweep attempt $attempt: ${#survivors[@]} surviving coordinator-loop process(es) for $PROJECT_ROOT: ${survivors[*]}"
  for s in "${survivors[@]}"; do
    kill_with_timeout "$s" 5 &
  done
  wait
done

mapfile -t still_alive < <(find_coordinator_loops "$PROJECT_ROOT")
if [[ "${#still_alive[@]}" -gt 0 ]]; then
  echo "ERROR: ${#still_alive[@]} coordinator-loop process(es) still alive after sweep: ${still_alive[*]}" >&2
  echo "       Inspect with: ps -fp ${still_alive[*]}" >&2
  exit 2
fi

echo "All coordinator-loop processes for $PROJECT_ROOT are stopped"
