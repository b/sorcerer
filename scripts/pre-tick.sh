#!/usr/bin/env bash
# Pre-tick deterministic steps. Runs the bookkeeping that doesn't need an
# LLM: state reconciliation, GitHub token refresh, and request-drain. The
# coordinator-loop.sh runs this BEFORE the tick LLM so the LLM starts from
# a clean, current state.
#
# Usage:
#   scripts/pre-tick.sh [project_root]
#
# Args:
#   project_root  Path to project root (default: $PWD). Operates on
#                 .sorcerer/ relative to this path.
#
# Steps:
#   1. Reconcile state — scan .sorcerer/architects/ for plan.json files
#      whose architect entry is missing from sorcerer.json (e.g. the LLM
#      had a stroke and dropped the entry); append a recovery entry.
#   2. Token refresh — if .sorcerer/.token-env is missing or its
#      GH_APP_TOKEN_EXPIRES_AT is within 600s, regenerate via
#      $SORCERER_REPO/scripts/refresh-token.sh.
#   3. Drain requests — for each .sorcerer/requests/*.md, mint a UUID,
#      move the request file to .sorcerer/architects/<id>/request.md,
#      append a pending-architect entry to sorcerer.json.
#
# Side effects:
#   - Mutates .sorcerer/sorcerer.json (atomic via tmp+rename).
#   - May write .sorcerer/.token-env.
#   - Appends events to .sorcerer/events.log.
#   - Moves files from .sorcerer/requests/ to .sorcerer/architects/<id>/.
#
# Exit: 0 on success. Non-zero only on jq/move/write failures (rare;
# coordinator-loop.sh treats this as fatal — corrupt state would propagate
# to the LLM tick and make things worse).
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] pre-tick: %s\n' "$(ts)" "$1"; }

mkdir -p .sorcerer

# Initialize sorcerer.json if missing; the LLM tick still expects to read it.
if [[ ! -f .sorcerer/sorcerer.json ]]; then
  echo '{"active_architects":[],"active_wizards":[],"providers_state":{},"paused_until":null}' \
    > .sorcerer/sorcerer.json
fi

# ---------- Step 1: reconcile state ----------
# For each .sorcerer/architects/<id>/ with plan.json AND no entry in
# active_architects, append a recovery entry at status=awaiting-tier-2.
recovered=0
if [[ -d .sorcerer/architects ]]; then
  for dir in .sorcerer/architects/*/; do
    [[ -d "$dir" ]] || continue
    arch_id="${dir#.sorcerer/architects/}"
    arch_id="${arch_id%/}"
    [[ -f "${dir}plan.json" ]] || continue
    have=$(jq -r --arg id "$arch_id" \
      '[(.active_architects // [])[] | select(.id == $id)] | length' \
      .sorcerer/sorcerer.json)
    [[ "$have" == "0" ]] || continue
    # Recover.
    epoch=$(stat -c %Y "$dir" 2>/dev/null || echo 0)
    started=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || ts)
    tmp=$(mktemp)
    jq --arg id "$arch_id" --arg started "$started" \
       --arg req ".sorcerer/architects/${arch_id}/request.md" \
       --arg plan ".sorcerer/architects/${arch_id}/plan.json" \
       '.active_architects += [{
          id: $id, status: "awaiting-tier-2", started_at: $started,
          request_file: $req, plan_file: $plan,
          pid: null, respawn_count: 0
        }]' .sorcerer/sorcerer.json > "$tmp" && mv "$tmp" .sorcerer/sorcerer.json
    log "reconciled orphan architect $arch_id"
    recovered=$((recovered + 1))
  done
fi
(( recovered > 0 )) && log "recovered $recovered architect(s)"

# ---------- Step 2: token refresh ----------
TOKEN_FILE=.sorcerer/.token-env
needs_refresh=0
if [[ ! -f "$TOKEN_FILE" ]]; then
  needs_refresh=1
else
  expires=$(grep GH_APP_TOKEN_EXPIRES_AT "$TOKEN_FILE" 2>/dev/null \
            | sed "s/.*='\([^']*\)'.*/\1/" || echo "")
  if [[ -z "$expires" ]]; then
    needs_refresh=1
  else
    expires_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    if (( expires_epoch - now_epoch < 600 )); then
      needs_refresh=1
    fi
  fi
fi
if (( needs_refresh )); then
  if bash "$SORCERER_REPO/scripts/refresh-token.sh" > "$TOKEN_FILE" 2>/dev/null; then
    printf '{"ts":"%s","event":"token-refreshed"}\n' "$(ts)" >> .sorcerer/events.log
    log "token refreshed"
  else
    log "token refresh failed (continuing; tick LLM may still have ambient auth)"
  fi
fi

# ---------- Step 3: drain requests ----------
# For each .sorcerer/requests/*.md not already tracked, generate an architect
# UUID, move the request to .sorcerer/architects/<id>/request.md, add a
# pending-architect entry to sorcerer.json.
drained=0
if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
  for req in .sorcerer/requests/*.md; do
    [[ -f "$req" ]] || continue
    # Skip if some architect entry already references this exact file.
    in_use=$(jq -r --arg f "$req" \
      '[(.active_architects // [])[] | select(.request_file == $f)] | length' \
      .sorcerer/sorcerer.json)
    [[ "$in_use" == "0" ]] || continue

    aid=$(uuidgen)
    mkdir -p ".sorcerer/architects/${aid}/logs"
    mv "$req" ".sorcerer/architects/${aid}/request.md"
    started=$(ts)
    tmp=$(mktemp)
    jq --arg id "$aid" --arg started "$started" \
       --arg req ".sorcerer/architects/${aid}/request.md" \
       '.active_architects += [{
          id: $id, status: "pending-architect", started_at: $started,
          request_file: $req, plan_file: null,
          pid: null, respawn_count: 0
        }]' .sorcerer/sorcerer.json > "$tmp" && mv "$tmp" .sorcerer/sorcerer.json
    log "drained request → architect $aid"
    drained=$((drained + 1))
  done
fi
(( drained > 0 )) && log "drained $drained request(s)"

exit 0
