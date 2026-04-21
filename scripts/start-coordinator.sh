#!/usr/bin/env bash
# Start the coordinator loop for a project, if not already running. Idempotent.
#
# Usage: scripts/start-coordinator.sh <project-root>
#
# The coordinator is a detached bash process running scripts/coordinator-loop.sh
# with the project root as its first arg. It runs the tick prompt repeatedly via
# `claude -p` until there is no pending work in <project>/.sorcerer/sorcerer.json,
# then exits cleanly. /sorcerer re-spawns it whenever a new request arrives.
set -euo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

STATE="$PROJECT_ROOT/.sorcerer"
PID_FILE="$STATE/coordinator.pid"
LOG_FILE="$STATE/coordinator.log"
mkdir -p "$STATE"

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Coordinator already running (pid $pid) for $PROJECT_ROOT"
    exit 0
  fi
  # stale pid file; fall through to start a fresh loop
  rm -f "$PID_FILE"
fi

nohup bash "$SORCERER_REPO/scripts/coordinator-loop.sh" "$PROJECT_ROOT" >> "$LOG_FILE" 2>&1 &
new_pid=$!
echo "$new_pid" > "$PID_FILE"
echo "Coordinator started (pid $new_pid) for $PROJECT_ROOT"
