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
ATTACH_PID_FILE="$STATE/attach.pid"

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

# If a previous attach is still running for this project, kill it before
# taking over. Claude Code backgrounds interrupted Bash calls; without this
# cleanup, every detach+reattach cycle leaves an orphan tail process behind.
if [[ -f "$ATTACH_PID_FILE" ]]; then
  prev="$(cat "$ATTACH_PID_FILE" 2>/dev/null || echo)"
  if [[ -n "$prev" ]] && kill -0 "$prev" 2>/dev/null; then
    kill "$prev" 2>/dev/null || true
    # Give it a moment to die before we overwrite the pid file.
    for _ in 1 2 3 4 5; do
      kill -0 "$prev" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$prev" 2>/dev/null || true
  fi
  rm -f "$ATTACH_PID_FILE"
fi

echo $$ > "$ATTACH_PID_FILE"
trap 'rm -f "$ATTACH_PID_FILE"' EXIT

echo "attached to coordinator for $PROJECT_ROOT (pid $pid)"
echo "Ctrl-C to detach; coordinator keeps running."
echo

# Orient the user with any recent events (tail last 20), then stream live.
if [[ -s "$EVENTS" ]]; then
  tail -n 20 "$EVENTS" | bash "$SORCERER_REPO/scripts/format-event.sh" || true
fi

# Stream new events; exit when the coordinator pid exits.
# `tail -n 0 -F --pid=$pid` follows the file and dies when the pid dies.
tail -n 0 -F --pid="$pid" "$EVENTS" 2>/dev/null \
  | bash "$SORCERER_REPO/scripts/format-event.sh"

echo
echo "coordinator exited; no in-flight work remaining."
