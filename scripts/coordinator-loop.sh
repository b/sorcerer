#!/usr/bin/env bash
# The sorcerer coordinator loop — runs per project.
#
# Usage: scripts/coordinator-loop.sh <project-root>
#
# Runs the tick prompt repeatedly via `claude -p` in the project's directory
# until there is no pending work in <project>/.sorcerer/sorcerer.json, then
# exits cleanly. /sorcerer re-spawns this loop (via start-coordinator.sh) when
# new requests arrive.
#
# Pending work = a file in .sorcerer/requests/, OR an active entry in
# .sorcerer/sorcerer.json with an in-flight status.
set -uo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }
cd "$PROJECT_ROOT"

if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.shell_env"
fi

# Defensive: env-inherited GH_APP_INSTALLATION_ID is a footgun. The launching
# shell may have previously sourced a different project's .token-env (e.g.
# b/sorcerer), leaving the wrong installation id in scope. Any inner
# refresh-token.sh call inheriting it would mint tokens for the wrong
# installation. Unset here so every child either re-sources THIS project's
# .token-env (which pre-tick.sh writes with the correct id) or invokes
# refresh-token.sh with --installation-owner / GH_APP_INSTALLATION_OWNER set
# below.
unset GH_APP_INSTALLATION_ID

# Export the owner derived from this project's first repo. refresh-token.sh
# uses this as the owner-filter when no --installation-id is given, so any
# child that calls it (mid-tick refreshes, ensure-bare-clones,
# preserve-wizard-wip) lands on the right installation without needing to
# parse config.json itself.
if [[ -f .sorcerer/config.json ]]; then
  _owner=$(jq -r '(.repos // [])[0] // empty' .sorcerer/config.json \
    | sed -E 's#^github\.com/##; s#/.*$##')
  [[ -n "$_owner" ]] && export GH_APP_INSTALLATION_OWNER="$_owner"
  unset _owner
fi

PID_FILE="$PROJECT_ROOT/.sorcerer/coordinator.pid"
TICK_PROMPT_FILE="$SORCERER_REPO/prompts/sorcerer-tick.md"

[[ -f "$TICK_PROMPT_FILE" ]] || { echo "ERROR: missing $TICK_PROMPT_FILE" >&2; exit 1; }
TICK_PROMPT="$(cat "$TICK_PROMPT_FILE")"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Exit-cause diagnostics --------------------------------------------------
# The coordinator has been observed silently dying between ticks. We don't have
# set -e, but `set -u` exits on unbound-variable access, and pipefail surfaces
# pipeline failures. Both trigger ERR. Log the offending line + command so the
# next time the loop dies, we have a traceable cause.
on_err() {
  local rc=$?
  echo "[$(ts)] coordinator-loop ERR rc=$rc line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}" >&2
}
trap on_err ERR

on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    echo "[$(ts)] coordinator-loop EXITING rc=$rc line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}" >&2
  fi
  rm -f "$PID_FILE"
}
trap on_exit EXIT

trap 'echo "[$(ts)] coordinator-loop received SIGTERM" >&2; exit 143' TERM
trap 'echo "[$(ts)] coordinator-loop received SIGHUP (shouldn'\''t happen under nohup)" >&2; exit 129' HUP
trap 'echo "[$(ts)] coordinator-loop received SIGINT" >&2; exit 130' INT

has_in_flight_work() {
  # See docs/lifecycle.md for the status taxonomy. The loop keeps running as
  # long as any entry is in a non-terminal state, OR any designer manifest
  # still has un-landed issues.
  if compgen -G ".sorcerer/requests/*.md" > /dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f .sorcerer/sorcerer.json ]]; then
    return 1
  fi

  # Primary signal: any architect or wizard entry in a non-terminal state.
  if jq -e '
      def entries: (.active_architects // []) + (.active_wizards // []);
      [entries[].status] | any(
        . == "pending-architect"           or
        . == "running"                     or
        . == "throttled"                   or
        . == "awaiting-architect-review"   or
        . == "architect-review-running"    or
        . == "awaiting-tier-2"             or
        . == "awaiting-design-review"      or
        . == "design-review-running"       or
        . == "awaiting-tier-3"             or
        . == "pending-design"              or
        . == "awaiting-review"             or
        . == "merging"
      )' .sorcerer/sorcerer.json > /dev/null 2>&1; then
    return 0
  fi

  # Defensive manifest check (designer tier). With slice-40's completion rule,
  # a designer should only be `completed` when every manifest issue has
  # merged/archived. But stale state files from before slice 40, or operator
  # intervention, can leave a `completed` designer with un-landed issues. In
  # that case treat the work as in-flight so step 8 gets a chance to
  # re-dispatch.
  mapfile -t manifests < <(jq -r '
    (.active_wizards // [])[]
    | select(.mode == "design" and .status == "completed")
    | .manifest_file // empty
  ' .sorcerer/sorcerer.json 2>/dev/null)
  for mf in "${manifests[@]}"; do
    [[ -z "$mf" || ! -f "$mf" ]] && continue
    mapfile -t manifest_ids < <(jq -r '(.issues // [])[].linear_id // empty' "$mf" 2>/dev/null)
    [[ ${#manifest_ids[@]} -eq 0 ]] && continue
    for id in "${manifest_ids[@]}"; do
      [[ -z "$id" ]] && continue
      landed=$(jq -r --arg id "$id" '
        [(.active_wizards // [])[]
         | select(.mode == "implement"
                  and .issue_linear_id == $id
                  and (.status == "merged" or .status == "archived"))]
        | length
      ' .sorcerer/sorcerer.json 2>/dev/null || echo 0)
      if [[ "$landed" == "0" ]]; then
        echo "[$(ts)] has_in_flight_work: designer manifest $mf has un-landed issue $id (defensive check)" >&2
        return 0
      fi
    done
  done

  # Defensive plan check (architect tier, symmetric to the designer check
  # above). With slice-41's completion rule, an architect should only be
  # `completed` when every sub-epic in plan.json has a completed/archived
  # designer. Before the fix — or on stale state — the architect could have
  # hit `completed` while a sub-epic sat un-spawned (cross-epic dep just
  # resolved between ticks). If ANY sub-epic in the plan lacks a
  # completed/archived designer entry, count as in-flight so step 6 gets to
  # reconsider on the next tick.
  mapfile -t plans < <(jq -r '
    (.active_architects // [])[]
    | select(.status == "completed")
    | "\(.id)\t\(.plan_file // "")"
  ' .sorcerer/sorcerer.json 2>/dev/null)
  for line in "${plans[@]}"; do
    [[ -z "$line" ]] && continue
    arch_id="${line%%$'\t'*}"
    plan_file="${line##*$'\t'}"
    [[ -z "$plan_file" || ! -f "$plan_file" ]] && continue
    mapfile -t sub_names < <(jq -r '(.sub_epics // [])[].name // empty' "$plan_file" 2>/dev/null)
    [[ ${#sub_names[@]} -eq 0 ]] && continue
    for name in "${sub_names[@]}"; do
      [[ -z "$name" ]] && continue
      done_count=$(jq -r --arg aid "$arch_id" --arg n "$name" '
        [(.active_wizards // [])[]
         | select(.mode == "design"
                  and .architect_id == $aid
                  and .sub_epic_name == $n
                  and (.status == "completed" or .status == "archived"))]
        | length
      ' .sorcerer/sorcerer.json 2>/dev/null || echo 0)
      if [[ "$done_count" == "0" ]]; then
        echo "[$(ts)] has_in_flight_work: architect $arch_id plan $plan_file has sub-epic '$name' without a completed designer (defensive check)" >&2
        return 0
      fi
    done
  done

  # Last-chance: even with sorcerer.json drained, Linear may still hold
  # non-terminal issues for this project's team that no live entry claims.
  # Without this check, the coordinator exits the moment in-memory state
  # empties and the Backlog never gets pulled in. Result is cached on
  # disk so we don't burn a `claude -p` query every loop iteration.
  if has_unclaimed_linear_work; then
    return 0
  fi

  return 1
}

# Cached Linear-work check. Calls scripts/has-linear-work.sh, caches the
# answer for LINEAR_WORK_CACHE_TTL seconds. Returns 0 if Linear has
# unclaimed non-terminal issues, 1 if not (or the helper is uncertain —
# "unknown" maps to 1 so the coordinator can still exit cleanly when
# Linear MCP is unreachable; the operator sees the helper's output in
# coordinator.log if anything looks off).
LINEAR_WORK_CACHE_TTL=300   # 5 minutes
LINEAR_WORK_CACHE_FILE=".sorcerer/.linear-work-cache"
has_unclaimed_linear_work() {
  local helper="$SORCERER_REPO/scripts/has-linear-work.sh"
  if [[ ! -x "$helper" ]]; then
    return 1   # helper not installed — degrade to old behavior
  fi
  local cached_age=999999 cached_value=""
  if [[ -f "$LINEAR_WORK_CACHE_FILE" ]]; then
    cached_age=$(( $(date +%s) - $(stat -c %Y "$LINEAR_WORK_CACHE_FILE" 2>/dev/null || echo 0) ))
    cached_value=$(cat "$LINEAR_WORK_CACHE_FILE" 2>/dev/null)
  fi
  local value=""
  if (( cached_age < LINEAR_WORK_CACHE_TTL )) && [[ -n "$cached_value" ]]; then
    value="$cached_value"
  else
    value=$(bash "$helper" "$PROJECT_ROOT" 2>/dev/null | tail -1)
    [[ -z "$value" ]] && value="unknown"
    printf '%s\n' "$value" > "$LINEAR_WORK_CACHE_FILE"
    echo "[$(ts)] linear-work-check: $value (helper queried, cached ${LINEAR_WORK_CACHE_TTL}s)"
  fi
  [[ "$value" == "yes" ]]
}

echo "[$(ts)] coordinator-loop started (pid $$) for $PROJECT_ROOT"

# Slice 56 — run the doctor's live-state checks at boot. Failures here are
# logged + escalated but do NOT stop the loop: degraded operation (some live
# checks failing) is preferable to silent stoppage. The first periodic
# re-run happens after DOCTOR_EVERY ticks.
DOCTOR_EVERY=30
TICK_COUNT=0

run_live_doctor() {
  local label="$1" rc=0
  echo "[$(ts)] doctor.sh --live-only ($label)"
  bash "$SORCERER_REPO/scripts/doctor.sh" --live-only "$PROJECT_ROOT" > "$STATE/last-doctor.log" 2>&1 || rc=$?
  if (( rc != 0 )); then
    # Echo the FAIL/WARN lines into coordinator.log so they're visible in
    # /sorcerer status without having to open last-doctor.log.
    grep -E '^\s*(FAIL|WARN)' "$STATE/last-doctor.log" 2>/dev/null | head -20 | while IFS= read -r ln; do
      echo "[$(ts)] doctor: $ln"
    done
    # One escalation per doctor failure; coord doesn't stack these (they tend
    # to repeat across many ticks until the operator acts).
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg rule "doctor-live-check-failed" \
      --arg label "$label" \
      --arg attempted "doctor.sh --live-only returned $rc; see $STATE/last-doctor.log for details" \
      --arg needs_from_user "Read $STATE/last-doctor.log; remediate the FAIL items. Coord continues running in degraded mode." \
      --arg log_path "$STATE/last-doctor.log" \
      '{ts:$ts, wizard_id:null, mode:"coordinator", issue_key:null, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user, label:$label, log_path:$log_path}' \
      >> "$STATE/escalations.log"
  fi
  return 0   # never propagate
}

STATE=".sorcerer"  # reused inside run_live_doctor for the escalation jq
mkdir -p "$STATE"
run_live_doctor "boot"

while true; do
  if ! has_in_flight_work; then
    echo "[$(ts)] no in-flight work; exiting"
    exit 0
  fi

  # Periodic doctor (slice 56). DOCTOR_EVERY ticks between live-only runs.
  TICK_COUNT=$((TICK_COUNT + 1))
  if (( TICK_COUNT % DOCTOR_EVERY == 0 )); then
    run_live_doctor "periodic-tick-$TICK_COUNT"
  fi

  # Honor a global pause set by the tick when too many rate-limit (429) errors
  # pile up. paused_until is an ISO-8601 timestamp; we sleep in 30s chunks so
  # a newly-arrived request or user Ctrl-C still gets noticed promptly.
  if [[ -f .sorcerer/sorcerer.json ]]; then
    paused_until=$(jq -r '.paused_until // ""' .sorcerer/sorcerer.json 2>/dev/null || echo "")
    if [[ -n "$paused_until" ]]; then
      now_epoch=$(date +%s)
      pause_epoch=$(date -d "$paused_until" +%s 2>/dev/null || echo 0)
      if (( pause_epoch > now_epoch )); then
        remain=$(( pause_epoch - now_epoch ))
        echo "[$(ts)] coordinator paused until $paused_until ($remain s remaining); sleeping"
        sleep $(( remain < 30 ? remain : 30 ))
        continue
      fi
    fi
  fi

  # Pre-tick: deterministic bookkeeping (state reconciliation, token refresh,
  # request drain, state-digest render, tick-mode classification). Runs in
  # bash so the LLM tick doesn't pay tokens for any of it. Output goes to
  # stdout, which the parent shell redirects to coordinator.log.
  bash "$SORCERER_REPO/scripts/pre-tick.sh" "$PROJECT_ROOT" || \
    echo "[$(ts)] pre-tick failed (rc=$?); continuing to tick anyway"

  # If pre-tick classified the tick as idle (no in-flight work, no pending
  # requests, no new escalations, and the consecutive-skip bound hasn't
  # been reached), skip the claude -p tick entirely. This is the dominant
  # cost-saver for projects that spend most of their time waiting on
  # single-slot wizard chains: ~50% of ticks were no-ops reading 81 KB to
  # report "0 of everything". classify-tick-mode.sh forces mechanical after
  # SORCERER_MAX_IDLE_SKIPS (default 5) consecutive idles so step-7 /
  # step-11d / Linear-orphan-sweeper still fire periodically.
  tick_mode=$(cat .sorcerer/.tick-mode 2>/dev/null || echo "mechanical")
  if [[ "$tick_mode" == "idle" ]]; then
    echo "[$(ts)] tick: idle — no in-flight work, skipping LLM"
    printf '{"ts":"%s","event":"tick-skipped-idle"}\n' "$(ts)" >> .sorcerer/events.log
    sleep 1
    continue
  fi

  echo "[$(ts)] running tick (mode=$tick_mode)"
  TICK_ARGS=(--output-format text --permission-mode bypassPermissions)
  TICK_LOG=".sorcerer/last-tick.log"

  # Pick the active provider (primary → fallback) and apply its env vars.
  # When config.providers is absent/empty, this is a no-op and the tick
  # runs against whatever ambient auth the caller has.
  tick_rc=0
  tick_provider=""
  (
    # Subshell so exported vars don't leak across loop iterations when the
    # active provider rotates. The claude -p inside inherits them.
    # shellcheck source=/dev/null
    source "$SORCERER_REPO/scripts/apply-provider-env.sh" \
      ".sorcerer/config.json" ".sorcerer/sorcerer.json"
    if [[ -n "$SORCERER_ACTIVE_PROVIDER" ]]; then
      echo "[$(ts)] tick provider: $SORCERER_ACTIVE_PROVIDER"
      tick_model=$(echo "$SORCERER_PROVIDER_MODELS" | jq -r '.coordinator // ""' 2>/dev/null || echo "")
    else
      tick_model=""
      [[ -n "$SORCERER_PROVIDER_REASON" ]] && echo "[$(ts)] tick provider: <none> ($SORCERER_PROVIDER_REASON)"
    fi
    if [[ -f .sorcerer/config.json ]]; then
      [[ -z "$tick_model"  ]] && tick_model=$(jq -r '.models.coordinator // ""' .sorcerer/config.json 2>/dev/null || echo "")
      tick_effort=$(jq -r '.effort.coordinator // ""' .sorcerer/config.json 2>/dev/null || echo "")
      [[ -n "$tick_model"  ]] && TICK_ARGS+=(--model  "$tick_model")
      [[ -n "$tick_effort" ]] && TICK_ARGS+=(--effort "$tick_effort")
    fi
    export SORCERER_ACTIVE_PROVIDER
    # Capture stdout+stderr to TICK_LOG AND to this loop's own stdout via tee,
    # so coordinator.log keeps showing tick output but we can also grep the log
    # for 429 markers after exit.
    #
    # Pipe the prompt via stdin instead of argv. Linux's MAX_ARG_STRLEN caps
    # any single argv string at 128KB (32 * PAGE_SIZE); the tick prompt has
    # grown past that ceiling and execve() fails with E2BIG before claude
    # even starts. Stdin has no such cap. `claude -p` reads its prompt from
    # stdin when no positional argument is supplied.
    if printf '%s' "$TICK_PROMPT" | claude -p "${TICK_ARGS[@]}" 2>&1 | tee "$TICK_LOG"; then
      : # tick succeeded
    else
      # PIPESTATUS[1] is the claude -p exit code now that printf is upstream
      # in the pipe (PIPESTATUS[0] = printf, [1] = claude, [2] = tee).
      exit "${PIPESTATUS[1]:-1}"
    fi
  )
  tick_rc=$?

  # Post-tick: deterministic cleanup (merged-PR cleanup with Linear→Done,
  # 7-day archival of terminal entries). Runs only on tick success — when
  # the tick failed (529/429/etc.) we want the next iteration to retry
  # the LLM rather than potentially mutate state on stale assumptions.
  # See scripts/post-tick.sh for the contract.
  if (( tick_rc == 0 )); then
    bash "$SORCERER_REPO/scripts/post-tick.sh" "$PROJECT_ROOT" || \
      echo "[$(ts)] post-tick failed (rc=$?); continuing"
  fi

  # --- Transient service-side overload (HTTP 529) ---------------------------
  # 529 is "Anthropic servers are overloaded" — NOT a rate-limit on this
  # account. Switching providers wouldn't help (Anthropic's backend is shared
  # across Max/API/Bedrock). The right response: short transient pause, let
  # the next iteration retry with the SAME provider. No provider-level
  # throttle, no per-provider state mutation.
  if (( tick_rc != 0 )) && [[ -f "$TICK_LOG" ]] \
     && grep -qE "API Error: 529|\"type\":[[:space:]]*\"overloaded_error\"|529 Overloaded" "$TICK_LOG"; then
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    pause_until=$(date -u -d "+60 seconds" +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p .sorcerer
    [[ -f .sorcerer/sorcerer.json ]] || echo '{}' > .sorcerer/sorcerer.json
    jq --arg pu "$pause_until" '.paused_until = $pu' .sorcerer/sorcerer.json \
      > .sorcerer/sorcerer.json.tmp && mv .sorcerer/sorcerer.json.tmp .sorcerer/sorcerer.json
    printf '{"ts":"%s","event":"coordinator-paused","paused_until":"%s","reason":"server-overload-529"}\n' \
      "$now_iso" "$pause_until" >> .sorcerer/events.log
    echo "[$(ts)] tick hit 529 overload; transient pause 60s until $pause_until"
    # Skip the 429-provider-marking block below; continue to next iteration.
    # (The paused_until just set will make the top-of-loop sleep skip this
    # iteration's tick.)
    continue
  fi

  # If the tick itself hit a rate limit, the in-tick throttle-detection logic
  # never ran (the tick died before it could write state). Do it here in the
  # loop so the NEXT iteration picks a different provider.
  #
  # Matches both the API error shape ("Request rejected (429)", etc.) and the
  # Max-subscription UI shape ("You've hit your limit · resets <when>"). The
  # Max variant is what Claude Code prints when an OAuth-logged-in subscription
  # runs out of its 5-hour bucket; there is no HTTP 429, just this line.
  if (( tick_rc != 0 )) && [[ -f "$TICK_LOG" ]] \
     && grep -qE "You've hit your limit|Request rejected \(429\)|\"type\":[[:space:]]*\"rate_limit_error\"|rate.limit.*exceeded" "$TICK_LOG"; then
    # Re-run the helper in a throwaway subshell just to identify which provider
    # was active for this tick. The helper is idempotent and doesn't write state.
    tick_provider=$(
      # shellcheck source=/dev/null
      source "$SORCERER_REPO/scripts/apply-provider-env.sh" \
        ".sorcerer/config.json" ".sorcerer/sorcerer.json" >/dev/null 2>&1
      printf '%s' "${SORCERER_ACTIVE_PROVIDER:-}"
    )
    if [[ -n "$tick_provider" ]]; then
      now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      # Prefer the exact reset timestamp when claude prints one. The Max
      # variant prints two shapes in the wild:
      #   "resets Apr 24, 1am (UTC)" — absolute when reset is >24h away
      #   "resets 1am (UTC)"         — relative when reset is within 24h
      #                                 (means "next occurrence of 1am UTC")
      # The regex below handles both plus optional ":30"-style minutes.
      # When the parsed time is in the past (relative form whose hour has
      # already passed today), roll forward one day to get "tomorrow at X".
      # Falls back to now+300s only when no reset string matches at all.
      throttled_until=""
      reset_line=$(grep -oE "resets ([A-Za-z]+ [0-9]+, )?[0-9]+(:[0-9]+)?\s*(am|pm|AM|PM)\s*\(?[A-Za-z]+\)?" "$TICK_LOG" 2>/dev/null | head -1 || true)
      if [[ -n "$reset_line" ]]; then
        reset_clean=$(echo "$reset_line" | sed -E 's/^resets //; s/\s*\(([^)]+)\)\s*$/ \1/; s/,//')
        parsed=$(date -u -d "$reset_clean" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        if [[ -n "$parsed" ]]; then
          parsed_epoch=$(date -u -d "$parsed" +%s 2>/dev/null || echo 0)
          now_epoch=$(date +%s)
          # Relative form that already passed today → bump to tomorrow.
          if (( parsed_epoch <= now_epoch )); then
            parsed=$(date -u -d "$parsed +1 day" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
            parsed_epoch=$(date -u -d "$parsed" +%s 2>/dev/null || echo 0)
          fi
          if (( parsed_epoch > now_epoch )); then
            throttled_until="$parsed"
            echo "[$(ts)] parsed reset time from log: $throttled_until"
          fi
        fi
      fi
      if [[ -z "$throttled_until" ]]; then
        throttled_until=$(date -u -d "+300 seconds" +%Y-%m-%dT%H:%M:%SZ)
      fi
      # Write throttle state. If sorcerer.json doesn't exist yet, seed it.
      mkdir -p .sorcerer
      [[ -f .sorcerer/sorcerer.json ]] || echo '{}' > .sorcerer/sorcerer.json
      jq --arg p "$tick_provider" --arg tu "$throttled_until" --arg ts "$now_iso" '
        .providers_state //= {}
        | .providers_state[$p] //= {throttle_count: 0}
        | .providers_state[$p].throttled_until    = $tu
        | .providers_state[$p].last_throttled_at  = $ts
        | .providers_state[$p].throttle_count     = ((.providers_state[$p].throttle_count // 0) + 1)
      ' .sorcerer/sorcerer.json > .sorcerer/sorcerer.json.tmp \
        && mv .sorcerer/sorcerer.json.tmp .sorcerer/sorcerer.json
      printf '{"ts":"%s","event":"provider-throttled","provider":"%s","throttled_until":"%s","source":"coordinator-tick"}\n' \
        "$now_iso" "$tick_provider" "$throttled_until" >> .sorcerer/events.log
      echo "[$(ts)] tick hit 429 on provider $tick_provider; marked throttled until $throttled_until; next iteration picks fallback"

      # If EVERY provider is now throttled, set global paused_until so the loop
      # sleeps until the earliest slot reopens. Matches the tick's own logic
      # for wizard-level rate-limit storms.
      total_providers=$(jq -r '(.providers // []) | length' .sorcerer/config.json 2>/dev/null || echo 0)
      throttled_count=$(jq -r --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        [(.providers // [])[].name as $n
         | ((.providers_state // {})[$n].throttled_until // "")
         | select(. != "" and . > $now)]
        | length
      ' <(jq -s '.[0] * .[1]' .sorcerer/config.json .sorcerer/sorcerer.json) 2>/dev/null || echo 0)
      if (( total_providers > 0 )) && (( throttled_count >= total_providers )); then
        earliest=$(jq -r --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
          [(.providers_state // {}) | to_entries[]
           | .value.throttled_until // empty
           | select(. > $now)]
          | sort | .[0] // ""
        ' .sorcerer/sorcerer.json 2>/dev/null || echo "")
        if [[ -n "$earliest" ]]; then
          jq --arg pu "$earliest" '.paused_until = $pu' .sorcerer/sorcerer.json \
            > .sorcerer/sorcerer.json.tmp && mv .sorcerer/sorcerer.json.tmp .sorcerer/sorcerer.json
          printf '{"ts":"%s","event":"coordinator-paused","paused_until":"%s","reason":"all-providers-throttled"}\n' \
            "$now_iso" "$earliest" >> .sorcerer/events.log
          echo "[$(ts)] all providers throttled; paused until $earliest"
        fi
      fi
    else
      echo "[$(ts)] tick hit 429 but no providers configured; coordinator cannot auto-route around it"
    fi
  elif (( tick_rc != 0 )); then
    echo "[$(ts)] tick exited non-zero ($tick_rc)"
  fi

  # Pacing: 30s while anything is actively running, 60s otherwise.
  if [[ -f .sorcerer/sorcerer.json ]] && jq -e '
      def entries: (.active_architects // []) + (.active_wizards // []);
      [entries[].status] | any(. == "running")
    ' .sorcerer/sorcerer.json > /dev/null 2>&1; then
    sleep 30
  else
    sleep 60
  fi
done
