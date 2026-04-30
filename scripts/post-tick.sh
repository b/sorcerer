#!/usr/bin/env bash
# Post-tick deterministic steps. Runs after the tick LLM, handles the
# bookkeeping that doesn't need LLM judgment: cleanup of merged-PR wizards
# (step 13) and 7-day archival of terminal entries (step 14).
#
# Usage:
#   scripts/post-tick.sh [project_root]
#
# Args:
#   project_root  Path to project root (default: $PWD). Operates on
#                 .sorcerer/ relative to this path.
#
# Steps performed:
#
#   13. Cleanup merged issues. For each wizard with mode=implement and
#       status=merging:
#       - Poll each PR's state via `gh pr view`. If all MERGED:
#         a. Run `git worktree remove` + `git branch -d` cleanup for each repo.
#         b. Push Linear → Done via scripts/linear-set-state.sh.
#         c. On Linear success: transition status=merged, append issue-merged
#            event, log `Merged and cleaned up: <issue_key>`.
#         d. On Linear failure: append linear-done-push-failed escalation,
#            leave status=merging, retry next tick.
#       - If some MERGED + some OPEN after >5 min: append partial-merge
#         escalation, status=blocked.
#       - If all OPEN after >5 min: append merge-blocked escalation,
#         status=blocked.
#
#       Reconciliation sweep: for each merged wizard within the last 7 days
#       (still in active_wizards, not yet archived), fetch its Linear status.
#       If status != Done, push it via linear-set-state.sh (drift recovery).
#
#   14. Archive entries past 7-day retention. Architects with status in
#       (completed, failed) and wizards with status in (merged, failed,
#       blocked) older than 7 days transition to status=archived; their
#       on-disk state dirs are removed. Append architect-archived /
#       wizard-archived events.
#
# Side effects (mutating .sorcerer/sorcerer.json atomically via tmp+rename):
#   - status transitions (merging→merged, merging→blocked, *→archived)
#   - Per-repo worktree removal and branch deletion (for cleaned-up wizards)
#   - State-dir removal (for archived entries)
#   - Linear API writes (status → Done) and reads (drift detection) via
#     scripts/linear-set-state.sh and scripts/linear-get-state.sh.
#   - Appends events to .sorcerer/events.log; appends to escalations.log.
#
# Exit: 0 always (failures surface as escalations or `pt:` log lines).
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
cd "$PROJECT_ROOT"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] post-tick: %s\n' "$(ts)" "$1"; }

[[ -f .sorcerer/sorcerer.json ]] || exit 0

now_epoch=$(date +%s)
seven_days_ago=$(( now_epoch - 7*86400 ))
five_min_ago=$(( now_epoch - 300 ))

state_file=.sorcerer/sorcerer.json
events_log=.sorcerer/events.log

# Atomic state mutation: read, mutate via jq, write tmp, rename.
mutate_state() {
  # $1 = jq filter (operates on the state object)
  # remaining args are jq --arg / --argjson pairs
  local filter="$1"; shift
  local tmp
  tmp=$(mktemp)
  jq "$@" "$filter" "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# ---------- Step 13: cleanup merged issues ----------
# Get the list of (id, issue_key, issue_linear_id, branch_name, started_at,
# repos_json, worktree_paths_json, pr_urls_json) for each merging wizard.
mapfile -t merging < <(
  jq -rc '
    (.active_wizards // [])[]
    | select(.mode == "implement" and .status == "merging")
    | [.id, .issue_key, .issue_linear_id, .branch_name, .started_at,
       (.repos // []), (.worktree_paths // {}), (.pr_urls // {})]
  ' "$state_file"
)

for entry in "${merging[@]}"; do
  read -r wid issue_key issue_linear_id branch_name started_at repos_json wt_json pr_json < <(
    echo "$entry" | jq -r '. | "\(.[0]) \(.[1]) \(.[2]) \(.[3]) \(.[4]) \(.[5] | @json) \(.[6] | @json) \(.[7] | @json)"'
  )

  # Re-shape because read above splits by IFS — pr_json may have spaces. Re-parse from JSON.
  repos_json=$(echo "$entry" | jq -c '.[5]')
  wt_json=$(echo "$entry"    | jq -c '.[6]')
  pr_json=$(echo "$entry"    | jq -c '.[7]')

  # Poll each PR's state. An empty response (gh auth failure, network blip,
  # rate limit, etc.) must NOT be conflated with "PR is in some non-terminal
  # state" — that'd mistakenly route the wizard to merge-blocked. Track the
  # gh failure as a defer signal and skip the wizard for this tick instead.
  all_merged=1
  any_open=0
  gh_failed=0
  while IFS= read -r pr_url; do
    [[ -z "$pr_url" ]] && continue
    state=$(gh pr view "$pr_url" --json state --jq .state 2>/dev/null || echo "")
    if [[ -z "$state" ]]; then
      gh_failed=1
      break
    fi
    if [[ "$state" != "MERGED" ]]; then
      all_merged=0
      [[ "$state" == "OPEN" ]] && any_open=1
    fi
  done < <(echo "$pr_json" | jq -r '.[]')

  if (( gh_failed )); then
    log "gh pr view failed for $issue_key (wizard $wid); deferring — likely a token/auth blip, retry next tick"
    continue
  fi

  started_epoch=$(date -u -d "$started_at" +%s 2>/dev/null || echo 0)

  if (( all_merged )); then
    # Worktree + branch cleanup per repo.
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      slug="${repo#github.com/}"
      bare=".sorcerer/repos/${slug//\//-}.git"
      tree=$(echo "$wt_json" | jq -r --arg k "$repo" '.[$k] // empty')
      if [[ -n "$tree" ]]; then
        git -C "$bare" worktree remove "$tree" 2>/dev/null || rm -rf "$tree" 2>/dev/null || true
      fi
      [[ -n "$branch_name" ]] && git -C "$bare" branch -d "$branch_name" 2>/dev/null || true
    done < <(echo "$repos_json" | jq -r '.[]')

    # Push Linear → Done.
    if [[ -n "$issue_linear_id" && "$issue_linear_id" != "null" ]]; then
      result=$(bash "$SORCERER_REPO/scripts/linear-set-state.sh" "$issue_linear_id" "Done" 2>/dev/null | tail -1)
    else
      result="ok"  # nothing to push
    fi

    if [[ "$result" == "ok" ]]; then
      mutate_state '
        .active_wizards |= map(
          if .id == $wid then .status = "merged" else . end
        )
      ' --arg wid "$wid"
      printf '{"ts":"%s","event":"issue-merged","id":"%s","issue_key":"%s"}\n' \
        "$(ts)" "$wid" "$issue_key" >> "$events_log"
      log "merged and cleaned up: $issue_key (wizard $wid)"

      # Secondary issue close: a single merged PR often shipped work tracked
      # by multiple Linear issues — the wizard's own SOR-N (its
      # issue_linear_id), AND extra issues cited in the PR title or body
      # ("Closes SOR-NNN", "Part of SOR-NNN", "(SOR-NNN)" suffix, etc.).
      # Without this scan, those extras stay In Progress forever because
      # no wizard owns them and the reconciliation sweep only iterates
      # wizards at status=merged. Scan each merged PR's title + body for
      # SOR-NNN references in close-ish contexts; for any that's currently
      # In Progress in Linear, flip to Done.
      while IFS= read -r pr_url; do
        [[ -z "$pr_url" ]] && continue
        pr_text=$(gh pr view "$pr_url" --json title,body --jq '.title + "\n" + .body' 2>/dev/null)
        [[ -z "$pr_text" ]] && continue

        # Extract SOR-NNN occurrences from "close-ish" contexts only:
        #   - "(SOR-NNN)" anywhere (title-suffix idiom)
        #   - line starting with Closes/Fixes/Resolves/Part of, optionally
        #     "Closes:", followed by SOR-NNN
        # This deliberately excludes "Depends on SOR-NNN" and inline
        # references in prose, which often point at separate work.
        extras=$(printf '%s' "$pr_text" \
          | grep -oiE '(\(SOR-[0-9]+\)|((Close[ds]?|Fix(e[ds])?|Resolve[ds]?|Part of)[ :]+SOR-[0-9]+))' \
          | grep -oiE 'SOR-[0-9]+' \
          | tr '[:lower:]' '[:upper:]' \
          | sort -u)

        for sor in $extras; do
          # Skip the wizard's own primary issue — already pushed above.
          [[ "$sor" == "$issue_key" ]] && continue

          current=$(bash "$SORCERER_REPO/scripts/linear-get-state.sh" "$sor" 2>/dev/null | tail -1)
          case "$current" in
            Done|done|DONE)
              # Already Done; quiet skip.
              ;;
            unknown|"")
              log "secondary check skipped for $sor (linear-get-state returned '$current')"
              ;;
            *)
              log "secondary close: $sor referenced in $pr_url, was '$current' — pushing Done"
              s_result=$(bash "$SORCERER_REPO/scripts/linear-set-state.sh" "$sor" "Done" 2>/dev/null | tail -1)
              if [[ "$s_result" == "ok" ]]; then
                printf '{"ts":"%s","event":"linear-secondary-done","wizard_id":"%s","issue_key":"%s","ref_pr":"%s","prior_status":"%s"}\n' \
                  "$(ts)" "$wid" "$sor" "$pr_url" "$current" >> "$events_log"
              else
                log "secondary push failed for $sor (result=$s_result); will retry next post-tick if PR is still in-flight"
              fi
              ;;
          esac
        done
      done < <(echo "$pr_json" | jq -r '.[]')
    else
      bash "$SORCERER_REPO/scripts/append-escalation.sh" "$wid" "implement" "$issue_key" \
        "linear-done-push-failed" \
        "linear-set-state.sh returned '$result' for $issue_key (Linear UUID $issue_linear_id)." \
        "Inspect Linear MCP auth (run /mcp), then the next post-tick will retry idempotently." \
        "$pr_json"
      log "linear-done-push failed for $issue_key (result=$result); leaving at merging"
    fi

  elif (( any_open )) && (( started_epoch < five_min_ago )); then
    # Some PRs merged, some still open after >5 min — partial-merge.
    bash "$SORCERER_REPO/scripts/append-escalation.sh" "$wid" "implement" "$issue_key" \
      "partial-merge" \
      "Wizard at status=merging for >5 min with mixed PR states: some MERGED, some OPEN. Inspect each PR." \
      "Find which PRs failed branch protection or required checks, fix, manually re-merge or refer back." \
      "$pr_json"
    mutate_state '.active_wizards |= map(if .id == $wid then .status = "blocked" else . end)' --arg wid "$wid"
    log "partial-merge for $issue_key; status → blocked"

  elif (( ! any_open )) && (( started_epoch < five_min_ago )); then
    # No PRs are OPEN but also not all are MERGED (e.g. CLOSED). Block.
    bash "$SORCERER_REPO/scripts/append-escalation.sh" "$wid" "implement" "$issue_key" \
      "merge-blocked" \
      "Wizard at status=merging for >5 min; PR states do not include any OPEN or all-MERGED — likely required-check failure or branch-protection denial." \
      "Inspect each PR's status; resolve the blocker manually or refer back via /sorcerer." \
      "$pr_json"
    mutate_state '.active_wizards |= map(if .id == $wid then .status = "blocked" else . end)' --arg wid "$wid"
    log "merge-blocked for $issue_key; status → blocked"
  fi
done

# ---------- Step 13 reconciliation sweep ----------
# For each implement wizard at status=merged within the last 7 days, ask
# Linear for the current state of:
#   (a) the wizard's own primary issue (.issue_linear_id) — drift recovery
#   (b) any secondary issues referenced from the wizard's PR(s) in
#       close-ish contexts ("Closes SOR-NNN", "Part of SOR-NNN",
#       "(SOR-NNN)" suffix). The wizards's own SOR is excluded from
#       the secondary scan.
# Both scans skip when current status is already Done. The secondary
# scan is gated by a per-wizard `secondary_scan_done: true` flag we
# set after the first successful walk so we don't re-scan PRs every
# tick — each wizard's PR set is scanned once (cheap, but compounds
# across N wizards × M ticks if not gated).
mapfile -t recently_merged < <(
  jq -rc --argjson cutoff "$seven_days_ago" '
    (.active_wizards // [])[]
    | select(.mode == "implement" and .status == "merged"
             and (.started_at | fromdate) > $cutoff)
    | [.id, .issue_key, (.issue_linear_id // ""), (.secondary_scan_done // false), (.pr_urls // {})]
  ' "$state_file"
)

for entry in "${recently_merged[@]}"; do
  wid=$(echo "$entry" | jq -r '.[0]')
  issue_key=$(echo "$entry" | jq -r '.[1]')
  issue_linear_id=$(echo "$entry" | jq -r '.[2]')
  secondary_done=$(echo "$entry" | jq -r '.[3]')
  reconc_pr_json=$(echo "$entry" | jq -c '.[4]')

  # (a) Primary-issue drift check (skip if no Linear ID was ever set,
  # e.g. orphan-adopted wizards).
  if [[ -n "$issue_linear_id" && "$issue_linear_id" != "null" ]]; then
    status=$(bash "$SORCERER_REPO/scripts/linear-get-state.sh" "$issue_linear_id" 2>/dev/null | tail -1)
    case "$status" in
      Done|done|DONE) ;;
      unknown|"")
        # MCP unavailable — quiet skip. Next sweep will retry.
        ;;
      *)
        log "linear-done-drift detected for $issue_key (Linear=$status); pushing now"
        result=$(bash "$SORCERER_REPO/scripts/linear-set-state.sh" "$issue_linear_id" "Done" 2>/dev/null | tail -1)
        if [[ "$result" == "ok" ]]; then
          printf '{"ts":"%s","event":"linear-done-reconciled","id":"%s","issue_key":"%s","prior_status":"%s"}\n' \
            "$(ts)" "$wid" "$issue_key" "$status" >> "$events_log"
        else
          bash "$SORCERER_REPO/scripts/append-escalation.sh" "$wid" "implement" "$issue_key" \
            "linear-done-push-failed" \
            "Reconciliation sweep: linear-set-state.sh returned '$result' for $issue_key (prior Linear=$status)." \
            "Inspect Linear MCP auth; sweep retries on every post-tick."
        fi
        ;;
    esac
  fi

  # (b) Secondary-issue scan, run at most once per wizard.
  if [[ "$secondary_done" != "true" ]]; then
    secondaries_attempted=0
    while IFS= read -r pr_url; do
      [[ -z "$pr_url" ]] && continue
      pr_text=$(gh pr view "$pr_url" --json title,body --jq '.title + "\n" + .body' 2>/dev/null)
      [[ -z "$pr_text" ]] && continue
      extras=$(printf '%s' "$pr_text" \
        | grep -oiE '(\(SOR-[0-9]+\)|((Close[ds]?|Fix(e[ds])?|Resolve[ds]?|Part of)[ :]+SOR-[0-9]+))' \
        | grep -oiE 'SOR-[0-9]+' \
        | tr '[:lower:]' '[:upper:]' \
        | sort -u)
      for sor in $extras; do
        [[ "$sor" == "$issue_key" ]] && continue
        secondaries_attempted=$((secondaries_attempted + 1))
        current=$(bash "$SORCERER_REPO/scripts/linear-get-state.sh" "$sor" 2>/dev/null | tail -1)
        case "$current" in
          Done|done|DONE) ;;
          unknown|"")
            log "secondary check skipped for $sor (linear-get-state returned '$current')"
            ;;
          *)
            log "secondary close (sweep): $sor referenced in $pr_url, was '$current' — pushing Done"
            s_result=$(bash "$SORCERER_REPO/scripts/linear-set-state.sh" "$sor" "Done" 2>/dev/null | tail -1)
            if [[ "$s_result" == "ok" ]]; then
              printf '{"ts":"%s","event":"linear-secondary-done","wizard_id":"%s","issue_key":"%s","ref_pr":"%s","prior_status":"%s","source":"reconc-sweep"}\n' \
                "$(ts)" "$wid" "$sor" "$pr_url" "$current" >> "$events_log"
            else
              log "secondary push failed for $sor (result=$s_result); will retry next sweep"
            fi
            ;;
        esac
      done
    done < <(echo "$reconc_pr_json" | jq -r 'to_entries[].value')

    # Mark secondary-scan-done so we don't re-walk this wizard's PRs every
    # tick. We set the flag even if zero secondaries were found (clean PR
    # body), and even if some pushes failed (we'll retry only on explicit
    # drift detection thereafter; the sweep is NOT the place to chase
    # transient Linear errors).
    mutate_state '
      .active_wizards |= map(
        if .id == $wid then .secondary_scan_done = true else . end
      )
    ' --arg wid "$wid"
  fi
done

# ---------- Step 14: archive 7-day-old terminal entries ----------
archived_count=0

# Architects: status in (completed, failed) older than 7 days.
mapfile -t arch_ids < <(
  jq -rc --argjson cutoff "$seven_days_ago" '
    (.active_architects // [])[]
    | select((.status == "completed" or .status == "failed")
             and (.started_at | fromdate) < $cutoff)
    | [.id, .status]
  ' "$state_file"
)
for entry in "${arch_ids[@]}"; do
  read -r arch_id prior_status < <(echo "$entry" | jq -r '. | "\(.[0]) \(.[1])"')
  rm -rf ".sorcerer/architects/${arch_id}" 2>/dev/null || true
  mutate_state '
    .active_architects |= map(
      if .id == $id then .status = "archived" | .archived_at = $now else . end
    )
  ' --arg id "$arch_id" --arg now "$(ts)"
  printf '{"ts":"%s","event":"architect-archived","id":"%s","prior_status":"%s"}\n' \
    "$(ts)" "$arch_id" "$prior_status" >> "$events_log"
  log "archived architect $arch_id (was $prior_status)"
  archived_count=$((archived_count + 1))
done

# Wizards: status in (merged, failed, blocked) older than 7 days.
mapfile -t wiz_ids < <(
  jq -rc --argjson cutoff "$seven_days_ago" '
    (.active_wizards // [])[]
    | select((.status == "merged" or .status == "failed" or .status == "blocked")
             and (.started_at | fromdate) < $cutoff)
    | [.id, .mode, .status, .state_dir // empty]
  ' "$state_file"
)
for entry in "${wiz_ids[@]}"; do
  read -r wid mode prior_status state_dir_field < <(
    echo "$entry" | jq -r '. | "\(.[0]) \(.[1]) \(.[2]) \(.[3] // "")"'
  )
  if [[ -n "$state_dir_field" && "$state_dir_field" != "null" ]]; then
    rm -rf "$state_dir_field" 2>/dev/null || true
  else
    rm -rf ".sorcerer/wizards/${wid}" 2>/dev/null || true
  fi
  mutate_state '
    .active_wizards |= map(
      if .id == $id then .status = "archived" | .archived_at = $now else . end
    )
  ' --arg id "$wid" --arg now "$(ts)"
  printf '{"ts":"%s","event":"wizard-archived","id":"%s","mode":"%s","prior_status":"%s"}\n' \
    "$(ts)" "$wid" "$mode" "$prior_status" >> "$events_log"
  log "archived wizard $wid ($mode, was $prior_status)"
  archived_count=$((archived_count + 1))
done

(( archived_count > 0 )) && log "archived $archived_count entries"

exit 0
