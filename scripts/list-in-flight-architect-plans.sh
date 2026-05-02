#!/usr/bin/env bash
# list-in-flight-architect-plans.sh
#
# Output a JSON array of in-flight architects' plans, each with a digest
# of its sub-epics' names, mandate excerpts, cited SOR-NNN identifiers,
# and repos. Used by spawn-wizard.sh's architect branch to inject the
# digest into a new architect's context.json so the architect can detect
# cross-architect sub-epic redundancy BEFORE emitting its own plan.
#
# Output schema (one entry per in-flight architect):
#   [
#     {
#       "architect_id": "<short uuid, 8 chars>",
#       "request_excerpt": "<first 200 chars of request.md, newlines collapsed>",
#       "sub_epics": [
#         {
#           "name": "<sub-epic name>",
#           "mandate_excerpt": "<first 400 chars of mandate>",
#           "cited_sors": ["SOR-NNN", ...],   // unique, sorted
#           "repos": ["<owner/repo>", ...]
#         }
#       ]
#     }
#   ]
#
# An architect with no plan.json yet (mid-decomposition) gets an entry
# with empty sub_epics. An architect with a malformed plan.json is
# skipped silently — overlap detection on a corrupt plan would mislead.
#
# Usage:
#   scripts/list-in-flight-architect-plans.sh [--exclude-id <uuid>] [project_root]
#
# Args:
#   --exclude-id <uuid>  Architect ID to omit from the result (typically
#                        the architect being spawned). Match is by the
#                        full UUID; no shortening.
#   project_root         Project root (default: $PWD).
#
# Exit: 0 always. Empty array `[]` when there are no in-flight
# architects (excluding the one being spawned).
set -euo pipefail

EXCLUDE_ID=""
PROJECT_ROOT=""

while (( $# )); do
  case "$1" in
    --exclude-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --exclude-id requires a value" >&2; exit 2; }
      EXCLUDE_ID="$2"; shift 2 ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    *)
      PROJECT_ROOT="$1"; shift ;;
  esac
done

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
cd "$PROJECT_ROOT"

# A plan is "in-flight" — and therefore overlap-relevant — when its
# architect has a non-terminal status. Once an architect completes,
# archives, or fails, its sub-epics are either landed (visible in
# main + Linear) or abandoned; either way, a NEW architect doesn't
# need to coordinate with it (landed work is already in main; failed
# work isn't going to ship).
NON_TERMINAL='[
  "pending-architect","running","throttled",
  "awaiting-architect-review","architect-review-running",
  "awaiting-tier-2"
]'

if [[ ! -f .sorcerer/sorcerer.json ]]; then
  echo "[]"
  exit 0
fi

# Collect in-flight architect IDs from sorcerer.json. Filter out the
# excluded one (if any). Output as newline-separated.
mapfile -t in_flight_ids < <(jq -r --argjson terms "$NON_TERMINAL" --arg exclude "$EXCLUDE_ID" '
  (.active_architects // [])
  | map(select(.status as $s | $terms | index($s)))
  | map(select(.id != $exclude))
  | .[] | .id
' .sorcerer/sorcerer.json)

if (( ${#in_flight_ids[@]} == 0 )); then
  echo "[]"
  exit 0
fi

# Build the digest array. jq doesn't have a native "for each file" loop
# we can use cleanly here, so we accumulate JSON in bash and re-parse
# at the end via jq for pretty-printing + final validation.
digests=()
for arch_id in "${in_flight_ids[@]}"; do
  plan=".sorcerer/architects/$arch_id/plan.json"
  request=".sorcerer/architects/$arch_id/request.md"

  if [[ -f "$plan" ]] && jq -e . "$plan" > /dev/null 2>&1; then
    # Plan exists and parses. Extract sub-epic digests.
    plan_part=$(jq --arg arch_short "${arch_id:0:8}" '
      {
        architect_id: $arch_short,
        sub_epics: [
          (.sub_epics // [])[]
          | {
              name: (.name // ""),
              mandate_excerpt: ((.mandate // "") | .[0:400]),
              cited_sors: ([(.mandate // "") + " " + (.name // "") | scan("SOR-[0-9]+")] | unique | sort),
              repos: (.repos // [])
            }
        ]
      }
    ' "$plan")
  else
    # Plan not yet written — architect is mid-decomposition. Emit a
    # placeholder so the new architect knows the slot is taken.
    plan_part=$(jq -n --arg arch_short "${arch_id:0:8}" '{architect_id: $arch_short, sub_epics: []}')
  fi

  # Add request_excerpt (read first 200 chars; collapse newlines so the
  # JSON output stays one-line-per-field).
  if [[ -f "$request" ]]; then
    plan_part=$(jq --rawfile req "$request" '
      . + {request_excerpt: ($req | .[0:200] | gsub("\n"; " ") | gsub("  +"; " ") | sub("^ +"; "") | sub(" +$"; ""))}
    ' <<< "$plan_part")
  else
    plan_part=$(jq '. + {request_excerpt: ""}' <<< "$plan_part")
  fi

  digests+=("$plan_part")
done

# Concatenate the per-architect JSON objects into a single array. Use
# jq -s . on the concatenated stream — it slurps multiple JSON values
# into an array.
printf '%s\n' "${digests[@]}" | jq -s '.'
exit 0
