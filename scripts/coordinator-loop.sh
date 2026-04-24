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

  # Defensive manifest check. With slice-40's completion rule, a designer
  # should only be `completed` when every manifest issue has merged/archived.
  # But stale state files from before slice 40, or operator intervention,
  # can leave a `completed` designer with un-landed issues. In that case
  # treat the work as in-flight so step 8 gets a chance to re-dispatch.
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

  return 1
}

echo "[$(ts)] coordinator-loop started (pid $$) for $PROJECT_ROOT"

while true; do
  if ! has_in_flight_work; then
    echo "[$(ts)] no in-flight work; exiting"
    exit 0
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

  echo "[$(ts)] running tick"
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
    if claude -p "${TICK_ARGS[@]}" "$TICK_PROMPT" < /dev/null 2>&1 | tee "$TICK_LOG"; then
      : # tick succeeded
    else
      # PIPESTATUS[0] is the claude -p exit code (tee can't fail in practice).
      exit "${PIPESTATUS[0]:-1}"
    fi
  )
  tick_rc=$?

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
