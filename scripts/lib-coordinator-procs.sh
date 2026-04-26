#!/usr/bin/env bash
# Helpers for finding coordinator-loop.sh processes by project root.
# Source this from stop / start / restart scripts; do not exec it.
#
# Background. The coordinator loop (`coordinator-loop.sh <project-root>`) spawns
# sub-bash subshells per tick. SIGKILL on the registered parent reparents these
# children to init (PPID=1), where they continue as orphan loops and split-brain
# the next tick (see escalations.log entries with rule:split-brain-coordinators).
# This helper enumerates ALL coordinator-loop.sh processes whose first arg
# matches a given project-root literally, so callers can sweep up orphans.
#
# Linux-only: relies on /proc/<pid>/cmdline. pgrep is from procps-ng.

# find_coordinator_loops <project-root-absolute>
# Prints pids of every `coordinator-loop.sh <project-root>` process to stdout,
# one per line, sorted ascending. Empty output means no loops alive.
#
# The match is a literal substring against the cmdline rendered with NUL→space
# (so "<script-path> <project-root> " — trailing space is the next-arg separator
# or the cmdline terminator). This avoids matching `<project-root>-foo` as a
# prefix of a different project's root.
find_coordinator_loops() {
  local project_root="$1"
  [[ -n "$project_root" ]] || return 0

  pgrep -f 'coordinator-loop\.sh' 2>/dev/null | while read -r p; do
    [[ -z "$p" ]] && continue
    local args
    args="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" || continue
    if [[ "$args" == *"coordinator-loop.sh $project_root "* ]]; then
      echo "$p"
    fi
  done | sort -n
}
