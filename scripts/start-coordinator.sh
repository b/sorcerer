#!/usr/bin/env bash
# Start the sorcerer coordinator loop if not already running. Idempotent.
#
# The coordinator is a detached bash process running scripts/coordinator-loop.sh.
# It runs the tick prompt repeatedly via `claude -p` until there is no pending
# work in state/sorcerer.yaml, then exits cleanly. /sorcerer re-spawns it as
# needed when new requests arrive.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PID_FILE="$REPO_ROOT/state/coordinator.pid"
LOG_FILE="$REPO_ROOT/state/coordinator.log"

mkdir -p "$REPO_ROOT/state"

if [[ -f "$PID_FILE" ]]; then
  pid=$(cat "$PID_FILE" 2>/dev/null || echo)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Coordinator already running (pid $pid)"
    exit 0
  fi
  # stale pid file (process gone); fall through to start a fresh loop
  rm -f "$PID_FILE"
fi

nohup bash "$REPO_ROOT/scripts/coordinator-loop.sh" >> "$LOG_FILE" 2>&1 &
new_pid=$!
echo "$new_pid" > "$PID_FILE"
echo "Coordinator started (pid $new_pid)"
