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
  # refresh-token.sh requires --installation-owner (or GH_APP_INSTALLATION_ID,
  # or the GH_APP_INSTALLATION_OWNER env) when more than one App installation
  # is reachable — which is the common case (org install + personal install).
  # Pull the primary owner from the first repo in config.json. If config has
  # no repos, fall back to the env var if set; otherwise skip the refresh
  # gracefully.
  owner=""
  if [[ -f .sorcerer/config.json ]]; then
    owner=$(jq -r '(.repos // [])[0] // empty' .sorcerer/config.json \
            | sed -E 's#^github\.com/##; s#/.*$##')
  fi
  [[ -z "$owner" ]] && owner="${GH_APP_INSTALLATION_OWNER:-}"

  if [[ -z "$owner" ]]; then
    log "token refresh skipped: no repos in config.json and GH_APP_INSTALLATION_OWNER unset"
  elif GH_APP_INSTALLATION_ID= bash "$SORCERER_REPO/scripts/refresh-token.sh" \
        --installation-owner "$owner" > "$TOKEN_FILE" 2>/dev/null; then
    printf '{"ts":"%s","event":"token-refreshed"}\n' "$(ts)" >> .sorcerer/events.log
    log "token refreshed (installation owner: $owner)"
  else
    log "token refresh failed for owner '$owner' (continuing; tick LLM may still have ambient auth)"
  fi
fi

# ---------- Step 2.5: ensure project label exists in Linear ----------
# Idempotent via .sorcerer/.linear-label-ok marker — burns one Haiku-backed
# Linear MCP call on first run for a project, then short-circuits. The
# label is required for designer issue creation (each new SOR issue gets
# the project label) and for multi-project disambiguation in
# has-linear-work / step-7 sweeper / design-review consistency.
bash "$SORCERER_REPO/scripts/ensure-linear-label.sh" "$PROJECT_ROOT" 2>&1 \
  | while IFS= read -r line; do log "$line"; done || true

# ---------- Step 2.6: ensure umbrella Linear project exists ----------
# Idempotent via .sorcerer/.linear-project-ok marker. The umbrella project
# is the Linear-side container for all of this sorcerer-project's issues —
# its UUID gets written to config.json:linear.project_uuid so the designer
# can pass it as projectId on every save_issue. One project per
# sorcerer-project (e.g. `archers`), NOT one per sub-epic — the per-sub-epic
# explosion was retired alongside save_project.
bash "$SORCERER_REPO/scripts/ensure-linear-project.sh" "$PROJECT_ROOT" 2>&1 \
  | while IFS= read -r line; do log "$line"; done || true

# Drain any .sorcerer/requests/*.md into pending-architect entries. Used
# both by step 3 below and by step 3.7 after auto-drain may have filed
# a new request.
drain_requests() {
  local n=0
  if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
    for req in .sorcerer/requests/*.md; do
      [[ -f "$req" ]] || continue
      # Skip if some architect entry already references this exact file.
      local in_use
      in_use=$(jq -r --arg f "$req" \
        '[(.active_architects // [])[] | select(.request_file == $f)] | length' \
        .sorcerer/sorcerer.json)
      [[ "$in_use" == "0" ]] || continue

      local aid started tmp
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
      n=$((n + 1))
    done
  fi
  (( n > 0 )) && log "drained $n request(s)"
  return 0
}

# ---------- Step 3: drain requests ----------
drain_requests

# ---------- Step 3.5: classify tick mode ----------
# Determine whether the upcoming LLM tick can be skipped (idle) or must run
# (mechanical / creative / recovery). Writes .sorcerer/.tick-mode.
# coordinator-loop.sh reads this file and skips the claude -p invocation
# entirely when mode=idle — bounded by SORCERER_MAX_IDLE_SKIPS so periodic
# LLM-side sweeps still fire eventually. Runs BEFORE auto-drain so we
# only auto-drain when the tick would otherwise be idle.
bash "$SORCERER_REPO/scripts/classify-tick-mode.sh" "$PROJECT_ROOT" || \
  log "classify-tick-mode failed (rc=$?); tick will run as mechanical"

# ---------- Step 3.7: auto-drain Linear backlog when idle ----------
# When the upcoming tick would be idle but Linear still has unclaimed
# non-terminal SOR issues, file a sorcerer drain request so the next
# tick spawns an architect to decompose the remaining backlog. Without
# this, the coordinator can sit idle indefinitely waiting for a manual
# /sorcerer prompt while backlog work piles up.
#
# Rate-limited via .sorcerer/.last-auto-drain (default 30min cooldown).
# When a request is filed, we re-run drain_requests() so it gets
# absorbed into a pending-architect entry on THIS tick — and then
# re-classify so .tick-mode reflects the new architect.
if [[ -x "$SORCERER_REPO/scripts/auto-drain-backlog.sh" ]]; then
  auto_drain_out=$(bash "$SORCERER_REPO/scripts/auto-drain-backlog.sh" "$PROJECT_ROOT" 2>&1 || true)
  [[ -n "$auto_drain_out" ]] && log "auto-drain: $auto_drain_out"
  if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
    log "auto-drain produced a new request; re-draining and re-classifying"
    drain_requests
    bash "$SORCERER_REPO/scripts/classify-tick-mode.sh" "$PROJECT_ROOT" || \
      log "classify-tick-mode (post-auto-drain) failed (rc=$?); tick will run as mechanical"
  fi
fi

# ---------- Step 3.8: render LLM-tick state digest ----------
# Generate .sorcerer/.tick-context.md — a compact state digest the LLM tick
# reads in place of dumping the full sorcerer.json. Keeps the LLM's working
# context small on long-lived projects with extensive merged-wizard history.
bash "$SORCERER_REPO/scripts/render-tick-context.sh" "$PROJECT_ROOT" || \
  log "render-tick-context failed (rc=$?); LLM tick will fall back to raw sorcerer.json"

exit 0
