#!/usr/bin/env bash
# Lint sorcerer prompt files for known-bad hedged-mandatory phrasings.
#
# Usage: scripts/lint-prompts.sh
#
# Exits 0 on clean. Exits 1 with FAIL listing on any hit.
#
# Background. The 2026-04-26 lifecycle-step-13 silent-drop bug (slice 49)
# was caused by a single parenthetical in `prompts/sorcerer-tick.md`:
# "(idempotent — Linear-GitHub integration may have done it)". The tick
# LLM read the hedge as license to skip the mandatory Linear push. The
# class of failure: an imperative state-changing instruction paired with
# a parenthetical / qualifier that lets the reader treat it as optional.
# Patterns we lint for are derived from observed incidents, not from
# guesses. Add new patterns conservatively — false positives waste signal.
#
# Ignore directive. A markdown comment `<!-- lint-prompt: ignore -->` on
# the immediately preceding line suppresses the next line's check. Use
# sparingly; the most common legit case is a docstring teaching about a
# past failure mode (the slice-49 retrospective in step 13 is the
# canonical example).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; RESET=$'\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; RESET=''
fi

# Patterns. Each entry is `<rule-name>|<extended-regex>|<one-line rationale>`.
# Extended regex; case-insensitive matching is set via grep -i below.
PATTERNS=(
  'idempotent-hedge|\bidempotent\b.*\b(may have|might have|already.*done)\b|Phrasing slice 49 fixed: an imperative paired with "idempotent — X may have done it" gets read as license to skip the call. Make the call mandatory; the idempotency is for the retry path, not the first-attempt path.'
  'integration-handles|\b(integration|webhook)\b[^.]*\bhandles?\b[^.]*\b(asynchronously|in the background|automatically|on its own)\b|Phrasing slice 49 fixed: deferring a state write to "the integration handles it asynchronously" was the actual silent-drop cause. The tick is the authoritative writer; do not delegate state-changing calls to a webhook whose timing/reliability sorcerer cannot verify.'
  'will-eventually|\bwill\s+eventually\b[^.]*\b(propagate|sync|reconcile|catch up)\b|Eventual-consistency hedges next to state writes encourage skipping. If reconciliation is the model, write it explicitly with a sweep step (slice 49 reconciliation-sweep pattern); do not promise eventual reach.'
)

fail=0
fail_lines=()

# Track the previous line to detect the ignore directive.
prev_line=""

shopt -s nullglob
prompts=(prompts/*.md)
shopt -u nullglob

if [[ ${#prompts[@]} -eq 0 ]]; then
  echo "lint-prompts: no prompts/*.md found"
  exit 0
fi

for f in "${prompts[@]}"; do
  prev_line=""
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    # Skip if previous line is an ignore directive
    if [[ "$prev_line" =~ \<!--[[:space:]]*lint-prompt:[[:space:]]*ignore[[:space:]]*--\> ]]; then
      prev_line="$line"
      continue
    fi
    # Skip lines that are themselves describing the bug shape inside quotes
    # / backticks (e.g. "Earlier prompt text labeled this call '...'") — a
    # quoted instance of the pattern is descriptive, not active.
    if [[ "$line" =~ \"[^\"]*idempotent[^\"]*\" || "$line" =~ \`[^\`]*idempotent[^\`]*\` ]]; then
      prev_line="$line"
      continue
    fi

    # Case-insensitive bash regex matching for the patterns below.
    shopt -s nocasematch
    for entry in "${PATTERNS[@]}"; do
      rule="${entry%%|*}"
      rest="${entry#*|}"
      regex="${rest%%|*}"
      rationale="${rest#*|}"
      if [[ "$line" =~ $regex ]]; then
        fail_lines+=("$f:$lineno: ${RED}FAIL${RESET} [$rule]")
        fail_lines+=("    line: $(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')")
        fail_lines+=("    rule: $rationale")
        fail_lines+=("    fix:  prefix the line with '<!-- lint-prompt: ignore -->' on the prior line if this is a deliberate retrospective; otherwise rewrite to remove the hedge.")
        fail=$((fail+1))
      fi
    done
    shopt -u nocasematch
    prev_line="$line"
  done < "$f"
done

if (( fail == 0 )); then
  echo "${GREEN}lint-prompts: clean${RESET} (${#prompts[@]} files, ${#PATTERNS[@]} patterns checked)"
  exit 0
fi

printf '\n'
for line in "${fail_lines[@]}"; do
  printf '%s\n' "$line"
done
printf '\n%slint-prompts: %d hit(s) across %d files%s\n' "$RED" "$fail" "${#prompts[@]}" "$RESET"
exit 1
