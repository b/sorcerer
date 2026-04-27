#!/usr/bin/env bash
# Lint every scripts/*.sh with `shellcheck --severity=error`. Prints PASS/FAIL
# per script; FAIL headers are followed by the diagnostic body. Exits 0 iff all
# scripts pass, non-zero otherwise. Self-lints (this file is part of the set).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint: shellcheck not found on PATH — install it (see docs/setup.md)" >&2
  exit 2
fi

shopt -s nullglob
scripts=(scripts/*.sh)
shopt -u nullglob

if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "no scripts to lint"
  exit 0
fi

pass=0
fail=0
for f in "${scripts[@]}"; do
  if out=$(shellcheck --severity=error "$f" 2>&1); then
    echo "PASS $f"
    pass=$((pass+1))
  else
    echo "FAIL $f"
    printf '%s\n' "$out"
    fail=$((fail+1))
  fi
done

echo "summary: $pass passed, $fail failed"
shellcheck_failed=$fail

# Slice 58 — prompt linter (hedged-mandatory phrasing). Independent pass; both
# must succeed for `lint.sh` to exit clean.
echo
echo "=== prompts/*.md (lint-prompts.sh) ==="
prompt_lint_rc=0
bash "$REPO_ROOT/scripts/lint-prompts.sh" || prompt_lint_rc=$?

if (( shellcheck_failed == 0 && prompt_lint_rc == 0 )); then
  exit 0
fi
exit 1
