#!/usr/bin/env bash
# Stop the sorcerer coordinator loop, if running.
# Sends SIGTERM, waits up to 10s, escalates to SIGKILL if needed.
# Removes the pid file regardless of how the process exits.
#
# Note: this stops the COORDINATOR loop, not any in-flight wizard sessions
# (architect/design/implement). Those run as their own detached processes
# and will continue to completion or exit on their own. To halt everything,
# also kill the spawned `claude -p` processes manually.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PID_FILE="$REPO_ROOT/state/coordinator.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "Coordinator not running (no pid file)"
  exit 0
fi

pid=$(cat "$PID_FILE" 2>/dev/null || echo)
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "Coordinator not running (stale pid: $pid)"
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping coordinator (pid $pid)..."
kill -TERM "$pid"

for i in {1..10}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "Coordinator stopped after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "Coordinator did not stop after SIGTERM; sending SIGKILL"
kill -KILL "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "Coordinator killed"
