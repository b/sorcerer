#!/usr/bin/env bash
# Restart the coordinator loop for a project: stop, then start.
#
# Usage: scripts/restart-coordinator.sh <project-root>
#
# Calls stop-coordinator.sh (which sweeps orphans), then start-coordinator.sh
# (which refuses to start if any orphan survived). With set -e, a stop that
# leaves survivors halts the script — no fresh loop is added on top of orphans.
#
# Exit codes:
#   0 — coordinator restarted cleanly (or, if it wasn't running, freshly started)
#   1 — bad argument (project root not a directory)
#   2 — stop or start refused due to surviving orphans
set -euo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

bash "$SORCERER_REPO/scripts/stop-coordinator.sh" "$PROJECT_ROOT"
bash "$SORCERER_REPO/scripts/start-coordinator.sh" "$PROJECT_ROOT"
