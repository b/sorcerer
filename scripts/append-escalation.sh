#!/usr/bin/env bash
# Append one escalation record to .sorcerer/escalations.log. Used by tick
# steps 5a, 5b, 5c, 11, etc. when a wizard or tick fails in a way the
# coordinator can't auto-recover from and the operator needs to look.
#
# Usage:
#   scripts/append-escalation.sh <wizard_id> <mode> <issue_key> <rule> <attempted> <needs_from_user> [pr_urls_json]
#
# Args:
#   wizard_id        UUID of the failing wizard (or "null" for tick-level failures).
#   mode             Wizard mode: architect | architect-review | design | design-review |
#                    implement | feedback | rebase | coordinator (for tick-level).
#   issue_key        Linear issue key for the failure (or "null" if not applicable).
#   rule             Short rule slug (e.g. "architect-no-output", "persistent-throttle").
#   attempted        One-line description of what was tried.
#   needs_from_user  One-line description of what the operator should do next.
#   pr_urls_json     Optional. JSON object {"<repo>": "<pr_url>", ...} or "null".
#                    Defaults to "null".
#
# Side effects: appends one JSON line to .sorcerer/escalations.log. Never
# overwrites; never reads.
#
# Exit: 0 on success, non-zero if jq fails (caller decides how to handle).
set -euo pipefail

WIZARD_ID="${1:?usage: $0 <wizard_id> <mode> <issue_key> <rule> <attempted> <needs_from_user> [pr_urls_json]}"
MODE="${2:?}"
ISSUE_KEY="${3:?}"
RULE="${4:?}"
ATTEMPTED="${5:?}"
NEEDS="${6:?}"
PR_URLS_JSON="${7:-null}"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -nc \
  --arg ts "$ts" \
  --arg wizard_id "$WIZARD_ID" \
  --arg mode "$MODE" \
  --arg issue_key "$ISSUE_KEY" \
  --arg rule "$RULE" \
  --arg attempted "$ATTEMPTED" \
  --arg needs_from_user "$NEEDS" \
  --argjson pr_urls "$PR_URLS_JSON" \
  '{
    ts: $ts,
    wizard_id: (if $wizard_id=="null" then null else $wizard_id end),
    mode: $mode,
    issue_key: (if $issue_key=="null" then null else $issue_key end),
    pr_urls: $pr_urls,
    rule: $rule,
    attempted: $attempted,
    needs_from_user: $needs_from_user
  }' >> .sorcerer/escalations.log
