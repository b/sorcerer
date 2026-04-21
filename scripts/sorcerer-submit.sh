#!/usr/bin/env bash
# Submit a feature request to sorcerer and ensure the coordinator is running.
#
# Usage: scripts/sorcerer-submit.sh "<prompt>"
#
# This script is the ENTIRE backing for the /sorcerer slash command.
# The skill itself issues only ONE Bash call (this one), so users can
# pre-approve it with a single allow rule in ~/.claude/settings.json
# (installed by scripts/install-skill.sh).
set -euo pipefail

if [[ -z "${SORCERER_REPO:-}" ]]; then
  cat >&2 <<EOF
ERROR: SORCERER_REPO env var is not set.

Set it to the absolute path of your sorcerer repo:
  echo 'export SORCERER_REPO=/path/to/sorcerer' >> ~/.shell_env
  source ~/.shell_env
EOF
  exit 1
fi
if [[ ! -d "$SORCERER_REPO" ]]; then
  echo "ERROR: SORCERER_REPO points to a non-existent directory: $SORCERER_REPO" >&2
  exit 1
fi
cd "$SORCERER_REPO"

PROMPT="${1:-}"
if [[ -z "$PROMPT" ]]; then
  cat >&2 <<'EOF'
Usage: /sorcerer <description of the system to build or refactor>

Sorcerer is for ambitious work — a new service, a cross-repo refactor, a
multi-component feature. Describe the desired end state; the architect
will decompose it.

Example:
  /sorcerer Build a real-time pricing service: ingestion from Kafka, in-memory
  cache backed by Redis, gRPC API for clients, Prometheus metrics.
EOF
  exit 2
fi

mkdir -p state/requests
TS=$(date -u +%Y%m%dT%H%M%SZ)
FIRST_LINE=$(printf '%s' "$PROMPT" | head -1)
SLUG=$(printf '%s' "$FIRST_LINE" | head -c 80 | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//' | head -c 60 | sed 's/-$//')
[[ -z "$SLUG" ]] && SLUG=request
FILE="state/requests/${TS}-${SLUG}.md"
printf '%s\n' "$PROMPT" > "$FILE"

echo "Request submitted: $FILE"
bash scripts/start-coordinator.sh

cat <<EOF

Sorcerer will autonomously:
  1. Architect — decompose the system into sub-epics with explicit boundaries
  2. Design — turn each sub-epic into a Linear epic with concrete issues
  3. Implement — spawn wizards to work each issue across the relevant repos
  4. Review — gate every PR set against acceptance criteria, then merge

Monitor:  tail -f $SORCERER_REPO/state/coordinator.log $SORCERER_REPO/state/events.log
Stop:     bash $SORCERER_REPO/scripts/stop-coordinator.sh
EOF
