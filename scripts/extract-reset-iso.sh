#!/usr/bin/env bash
# Extract the reset timestamp from a "resets <when> (<tz>)" line in a wizard
# log. Used by the 429 rate-limit handling path to populate
# providers_state[$P].throttled_until with a precise window instead of the
# 5-minute default.
#
# Usage:
#   scripts/extract-reset-iso.sh <log_path>
#
# Handles BOTH shapes Claude Code prints in 429 messages:
#   "resets Apr 24, 1am (UTC)"   — absolute form when reset > 24h away
#   "resets 1am (UTC)"           — relative form when reset ≤ 24h away
# Tolerates optional ":30"-style minutes. When the relative form's hour has
# already passed today, rolls forward one day to "tomorrow at X".
#
# Output: ISO-8601 UTC timestamp on stdout, exit 0.
# Exit 1 (no output) when:
#   - no "resets" line in the log
#   - the parsed timestamp can't be normalized
#   - the parsed timestamp is in the past even after the +1 day rollover
set -euo pipefail

LOG="${1:?usage: $0 <log_path>}"
[[ -f "$LOG" ]] || exit 1

line=$(grep -oE "resets ([A-Za-z]+ [0-9]+, )?[0-9]+(:[0-9]+)?\s*(am|pm|AM|PM)\s*\(?[A-Za-z]+\)?" "$LOG" 2>/dev/null | head -1)
[[ -z "$line" ]] && exit 1

clean=$(echo "$line" | sed -E 's/^resets //; s/\s*\(([^)]+)\)\s*$/ \1/; s/,//')
parsed=$(date -u -d "$clean" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 1
parsed_epoch=$(date -u -d "$parsed" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
if (( parsed_epoch <= now_epoch )); then
  parsed=$(date -u -d "$parsed +1 day" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 1
  parsed_epoch=$(date -u -d "$parsed" +%s 2>/dev/null || echo 0)
fi
(( parsed_epoch > now_epoch )) || exit 1
printf '%s\n' "$parsed"
