#!/usr/bin/env bash
# Stop the coordinator loop for a project, if running.
#
# Usage: scripts/stop-coordinator.sh <project-root>
#
# Sends SIGTERM, waits up to 10s, escalates to SIGKILL if needed. Removes the
# pid file regardless of how the process exits. Does not stop any in-flight
# wizard sessions (they run as independent detached processes).
set -uo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

PID_FILE="$PROJECT_ROOT/.sorcerer/coordinator.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "Coordinator not running for $PROJECT_ROOT (no pid file)"
  exit 0
fi

pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "Coordinator not running (stale pid: $pid)"
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping coordinator (pid $pid) for $PROJECT_ROOT..."
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
