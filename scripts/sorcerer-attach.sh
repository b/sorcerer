#!/usr/bin/env bash
# Attach to the coordinator for the current project (or the project passed as
# argument). Streams formatted event-log lines to stdout until the coordinator
# exits or the user interrupts.
#
# Usage: scripts/sorcerer-attach.sh [<project-root>]
#
# When the coordinator exits cleanly (no in-flight work remaining), this
# script exits too. When the user interrupts (Ctrl-C or otherwise), the
# coordinator keeps running — it's detached from this attach session.
set -uo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

STATE="$PROJECT_ROOT/.sorcerer"
EVENTS="$STATE/events.log"
PID_FILE="$STATE/coordinator.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "No coordinator running for $PROJECT_ROOT."
  echo "Submit work with:  /sorcerer <prompt>"
  exit 0
fi

pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "Coordinator is not alive (stale pid: $pid). Submit new work with /sorcerer <prompt> to respawn."
  exit 0
fi

echo "attached to coordinator for $PROJECT_ROOT (pid $pid)"
echo "Ctrl-C to detach; coordinator keeps running."
echo

# Orient the user with any recent events (tail last 20), then stream live.
if [[ -s "$EVENTS" ]]; then
  tail -n 20 "$EVENTS" | python3 "$SORCERER_REPO/scripts/format-event.py" || true
fi

# Stream new events; exit when the coordinator pid exits.
# `tail -n 0 -F --pid=$pid` follows the file and dies when the pid dies.
tail -n 0 -F --pid="$pid" "$EVENTS" 2>/dev/null \
  | python3 "$SORCERER_REPO/scripts/format-event.py"

echo
echo "coordinator exited; no in-flight work remaining."
