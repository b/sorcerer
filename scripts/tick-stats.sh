#!/usr/bin/env bash
# tick-stats.sh
#
# Summarize coordinator activity from .sorcerer/events.log:
#   - Tick-mode distribution (full LLM ticks vs idle skips)
#   - Effective tick cadence (start-to-start gap, p50/mean/p90)
#   - Wizard / architect lifecycle counts
#   - Throttle / pause activity
#   - Issue-merge throughput
#
# Used to evaluate the impact of the idle-skip + lazy-load changes
# without having to grep events.log by hand. Print a clean human-readable
# block (no JSON) intended for terminal viewing.
#
# Usage:
#   scripts/tick-stats.sh [project_root] [window]
#
# Args:
#   project_root  Path to project root (default: $PWD).
#   window        Time window: "1h" | "24h" | "7d" | "all" (default: "24h").
#                 The window is wall-clock from now.
#
# Exit: 0 always. If events.log is missing, prints a clear message and exits 0.
set -euo pipefail

PROJECT_ROOT="${1:-$PWD}"
WINDOW="${2:-24h}"

case "$WINDOW" in
  1h)  cutoff_seconds_ago=3600 ;;
  24h) cutoff_seconds_ago=86400 ;;
  7d)  cutoff_seconds_ago=604800 ;;
  all) cutoff_seconds_ago=999999999 ;;
  *)   echo "tick-stats: unknown window '$WINDOW'; use 1h | 24h | 7d | all" >&2; exit 2 ;;
esac

cd "$PROJECT_ROOT"

LOG=".sorcerer/events.log"
if [[ ! -f "$LOG" ]]; then
  echo "tick-stats: $LOG not found in $PROJECT_ROOT"
  exit 0
fi

now_epoch=$(date +%s)
cutoff_epoch=$(( now_epoch - cutoff_seconds_ago ))
cutoff_iso=$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ)

# Filter the log to events within window. We keep both the JSON line and an
# epoch column for downstream cadence math.
filtered=$(awk -v cutoff="$cutoff_epoch" '
  {
    if (match($0, /"ts":"[^"]+"/)) {
      ts_field = substr($0, RSTART+6, RLENGTH-7)
      cmd = "date -u -d \"" ts_field "\" +%s 2>/dev/null"
      if ((cmd | getline e) > 0 && e >= cutoff) {
        print e "\t" $0
      }
      close(cmd)
    }
  }
' "$LOG")

if [[ -z "$filtered" ]]; then
  echo "tick-stats: no events in the last $WINDOW (since $cutoff_iso)"
  exit 0
fi

events_total=$(wc -l <<< "$filtered" | tr -d ' ')
window_first_epoch=$(head -1 <<< "$filtered" | cut -f1)
window_last_epoch=$(tail -1 <<< "$filtered" | cut -f1)
span_seconds=$(( window_last_epoch - window_first_epoch ))
(( span_seconds < 1 )) && span_seconds=1
window_first_iso=$(date -u -d "@$window_first_epoch" +%Y-%m-%dT%H:%M:%SZ)
window_last_iso=$(date -u -d "@$window_last_epoch" +%Y-%m-%dT%H:%M:%SZ)

# Counts by event type, sorted descending.
event_counts=$(cut -f2 <<< "$filtered" \
  | jq -r '.event' 2>/dev/null \
  | sort | uniq -c | sort -rn)

count_of() {
  local ev="$1"
  awk -v e="$ev" '$2 == e { print $1; exit }' <<< "$event_counts"
}

ticks_full=$(count_of tick-complete)
ticks_idle=$(count_of tick-skipped-idle)
: "${ticks_full:=0}"
: "${ticks_idle:=0}"
ticks_total=$(( ticks_full + ticks_idle ))

if (( ticks_total > 0 )); then
  idle_pct=$(awk -v i="$ticks_idle" -v t="$ticks_total" 'BEGIN{printf "%.1f", (i/t)*100}')
  full_pct=$(awk -v f="$ticks_full" -v t="$ticks_total" 'BEGIN{printf "%.1f", (f/t)*100}')
else
  idle_pct=0.0; full_pct=0.0
fi

# Cadence: start-to-start gap between consecutive tick-complete OR
# tick-skipped-idle events. Both kinds delimit a tick boundary.
cadence_gaps=$(awk -v cutoff="$cutoff_epoch" '
  {
    if (match($0, /"event":"(tick-complete|tick-skipped-idle)"/)) {
      e = $1
      if (prev > 0) print e - prev
      prev = e
    }
  }
' <<< "$filtered")

cadence_summary="(insufficient samples)"
if [[ -n "$cadence_gaps" ]]; then
  cadence_summary=$(sort -n <<< "$cadence_gaps" | awk '
    { v[NR]=$1; sum+=$1 }
    END {
      n=NR
      if (n == 0) { printf "(none)"; exit }
      p50=v[int(n*0.5)+0]; p90=v[int(n*0.9)+0]; p99=v[int(n*0.99)+0]
      printf "n=%d  min=%ds  p50=%ds  mean=%.0fs  p90=%ds  p99=%ds  max=%ds",
        n, v[1], p50, sum/n, p90, p99, v[n]
    }')
fi

# Lifecycle counts.
arch_spawned=$(count_of architect-spawned);    : "${arch_spawned:=0}"
arch_completed=$(count_of architect-completed);: "${arch_completed:=0}"
designer_spawned=$(count_of designer-spawned); : "${designer_spawned:=0}"
designer_completed=$(count_of designer-completed); : "${designer_completed:=0}"
implement_spawned=$(count_of implement-spawned); : "${implement_spawned:=0}"
implement_completed=$(count_of implement-completed); : "${implement_completed:=0}"
issue_merged=$(count_of issue-merged);  : "${issue_merged:=0}"
review_refer_back=$(count_of review-refer-back); : "${review_refer_back:=0}"

# Trouble counts.
wizard_throttled=$(count_of wizard-throttled); : "${wizard_throttled:=0}"
provider_throttled=$(count_of provider-throttled); : "${provider_throttled:=0}"
coord_paused=$(count_of coordinator-paused); : "${coord_paused:=0}"
escalations_event=$(count_of escalation); : "${escalations_event:=0}"
wizard_overloaded=$(count_of wizard-overloaded); : "${wizard_overloaded:=0}"

# Print the report.
printf '\n'
printf '== Sorcerer tick stats =====================================\n'
printf '  project:    %s\n' "$PROJECT_ROOT"
printf '  window:     %s  (since %s)\n' "$WINDOW" "$cutoff_iso"
printf '  earliest:   %s\n' "$window_first_iso"
printf '  latest:     %s\n' "$window_last_iso"
printf '  events:     %d  in %ds (%s wall-clock)\n' \
  "$events_total" "$span_seconds" \
  "$(awk -v s="$span_seconds" 'BEGIN{
    if(s<60)printf"%ds",s; else if(s<3600)printf"%.1fm",s/60; else if(s<86400)printf"%.1fh",s/3600; else printf"%.1fd",s/86400
  }')"
echo
echo '-- Tick mode distribution -----------------------------------'
printf '  full LLM ticks:   %5d  (%5s%%)\n' "$ticks_full" "$full_pct"
printf '  idle skips:       %5d  (%5s%%)\n' "$ticks_idle" "$idle_pct"
printf '  total ticks:      %5d\n' "$ticks_total"
if (( ticks_total > 0 && span_seconds > 60 )); then
  rate_full_per_h=$(awk -v t="$ticks_full" -v s="$span_seconds" 'BEGIN{printf "%.2f", t/(s/3600.0)}')
  rate_total_per_h=$(awk -v t="$ticks_total" -v s="$span_seconds" 'BEGIN{printf "%.2f", t/(s/3600.0)}')
  printf '  rate (per hour):  full=%s  total=%s\n' "$rate_full_per_h" "$rate_total_per_h"
fi
echo
echo '-- Tick cadence (start-to-start gap, both kinds) -----------'
printf '  %s\n' "$cadence_summary"
echo
echo '-- Lifecycle ------------------------------------------------'
printf '  architects:   spawned=%d  completed=%d\n' "$arch_spawned" "$arch_completed"
printf '  designers:    spawned=%d  completed=%d\n' "$designer_spawned" "$designer_completed"
printf '  implements:   spawned=%d  completed=%d\n' "$implement_spawned" "$implement_completed"
printf '  issues:       merged=%d   refer-backs=%d\n' "$issue_merged" "$review_refer_back"
printf '\n'
if (( wizard_throttled + provider_throttled + coord_paused + wizard_overloaded > 0 )); then
  echo '-- Trouble --------------------------------------------------'
  printf '  wizard-throttled:    %d\n' "$wizard_throttled"
  printf '  provider-throttled:  %d\n' "$provider_throttled"
  printf '  wizard-overloaded:   %d\n' "$wizard_overloaded"
  printf '  coordinator-paused:  %d\n' "$coord_paused"
  echo
fi
echo '-- All event types in window --------------------------------'
echo "$event_counts" | sed 's/^/  /'
echo

exit 0
