#!/usr/bin/env bash
# Format sorcerer event-log entries (JSONL) into human-readable progress lines.
#
# Reads JSONL from stdin. Each line is {ts, event, ...}. Emits one pretty line
# per known event to stdout. Silent on unknown events so the stream doesn't
# drown in noise (e.g. tick-complete).
set -euo pipefail

jq -r '
  def short(v): (v // "" | tostring) | .[0:8];
  (.event // "") as $e |
  (
    if $e == "token-refreshed" then
      "GitHub token refreshed"
    elif $e == "architect-spawned" then
      "Architect spawned (id: \(short(.id)))"
    elif $e == "architect-completed" then
      (.sub_epics // []) as $se
      | ($se | length) as $n
      | ($se | .[0:3] | join(", ")) as $preview
      | (if $n > 3 then " (+\($n - 3) more)" else "" end) as $extra
      | "Architect completed: \($n) sub-epic(s) — \($preview)\($extra)"
    elif $e == "architect-archived" then
      "Archived architect \(short(.id)) (prior: \(.prior_status))"
    elif $e == "designer-spawned" then
      "Designer spawned for sub-epic '\''\(.sub_epic)'\'' (id: \(short(.id)))"
    elif $e == "designer-completed" then
      "Designer completed: \(.issues) issue(s)\(if .epic_linear_id then " (legacy epic \(short(.epic_linear_id)))" else "" end)"
    elif $e == "architect-review-spawned" then
      "Architect-review spawned for \(short(.subject_id)) (reviewer: \(short(.id)))"
    elif $e == "architect-review-completed" then
      "Architect-review completed for \(short(.subject_id)): \(.decision)\(if .edits then " (\(.edits) edit(s))" else "" end)"
    elif $e == "design-review-spawned" then
      "Design-review spawned for designer \(short(.subject_id)) (reviewer: \(short(.id)))"
    elif $e == "design-review-completed" then
      "Design-review completed for designer \(short(.subject_id)): \(.decision)\(if .edits then " (\(.edits) edit(s))" else "" end)"
    elif $e == "implement-spawned" then
      "Implement wizard spawned on \(.issue_key) (pid \(.pid))"
    elif $e == "implement-completed" then
      (if .cycle then " (cycle \(.cycle))" else "" end) as $extra
      | "Implement completed\($extra): \(.issue_key), \(.pr_count) PR(s) opened"
    elif $e == "feedback-completed" then
      "Feedback cycle \(.cycle) done on \(.issue_key)"
    elif $e == "review-merge" then
      "Review passed; merging \(.issue_key) (\(.pr_count) PR(s))"
    elif $e == "review-refer-back" then
      "Refer-back (cycle \(.cycle)): \(.issue_key) — see \(.primary_pr)"
    elif $e == "review-rebase" then
      "Rebase needed (cycle \(.cycle)): \(.issue_key) — \((.offending_repos // []) | join(", "))"
    elif $e == "rebase-completed" then
      "Rebase cycle \(.cycle) done on \(.issue_key); re-queueing for review"
    elif $e == "wizard-throttled" then
      "Throttled (\(.mode) \(short(.id))): retry after \(.retry_after)"
    elif $e == "wizard-overloaded" then
      "Overloaded 529 (\(.mode) \(short(.id))): retry after \(.retry_after)\(if .overload_count then " (strike #\(.overload_count))" else "" end)"
    elif $e == "wizard-killed-max-age" then
      "KILLED (max-age) \(.mode) \(short(.id)) — ran \(.age_seconds)s, over the cap for this mode; escalated"
    elif $e == "wizard-resumed" then
      "Resumed (\(.mode) \(short(.id))) after throttle #\(.throttle_count)"
    elif $e == "provider-throttled" then
      "Provider throttled: \(.provider) until \(.throttled_until)"
    elif $e == "pr-set-recovered" then
      "Recovered \(.issue_key) from stale heartbeat — \(.pr_count) open PR(s) already on GitHub; queued for review"
    elif $e == "coordinator-paused" then
      "Coordinator paused until \(.paused_until) — \(.reason)"
    elif $e == "coordinator-resumed" then
      "Coordinator resumed"
    elif $e == "issue-merged" then
      "Merged and cleaned up: \(.issue_key)"
    elif $e == "wizard-archived" then
      "Archived wizard \(short(.id)) (\(.mode), prior: \(.prior_status))"
    elif ($e | endswith("-stale-respawn")) then
      "Stale respawn: \($e | sub("-stale-respawn$"; "")) \(short(.id))"
    else
      ""
    end
  ) as $msg
  | if $msg == "" then empty else "[\(.ts // "")] \($msg)" end
'
