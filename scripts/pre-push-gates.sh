#!/usr/bin/env bash
# pre-push-gates.sh
#
# Run the workspace's CI-equivalent gates locally so wizards don't push
# PRs that fail on routine checks (formatting, lint, build, tests). Each
# failed gate burns an Opus run on a refer-back cycle that `cargo fmt
# --all` (or its language equivalent) would have fixed for free.
#
# Wizards invoke this from Phase 7 of `prompts/wizard-implement.md`
# (and equivalents). Centralized here so the gate set can evolve
# without churning every wizard prompt.
#
# Usage:
#   bash $SORCERER_REPO/scripts/pre-push-gates.sh <worktree-path>
#
# Detection: looks at files at the worktree root.
#   - `Cargo.toml` present       → run Rust gates
#   - (other languages later)
#   - none of the above          → no language-specific gates; exit 0
#
# Output: every gate's stdout/stderr is streamed in real time (no
# buffering / capture), so the wizard sees compile errors and test
# failures as they occur. The script prefixes each gate with a header
# so wizards can locate the failing block by scanning for `== gate:`
# markers.
#
# Exit:
#   0 — all gates passed (or no language detected).
#   1 — at least one gate failed; the failing gate's name + exit code
#       is printed; its output is the last block before the FAIL line.
#   2 — usage error (missing/invalid worktree path).
set -uo pipefail

WORKTREE="${1:-}"
if [[ -z "$WORKTREE" ]]; then
  echo "Usage: $0 <worktree-path>" >&2
  exit 2
fi
if [[ ! -d "$WORKTREE" ]]; then
  echo "ERROR: worktree is not a directory: $WORKTREE" >&2
  exit 2
fi

cd "$WORKTREE" || { echo "ERROR: cannot cd to $WORKTREE" >&2; exit 2; }

# run_gate <human-readable name> <command> [args...]
# Streams output (no capture). Returns the command's exit code.
run_gate() {
  local name="$1"; shift
  echo
  echo "== gate: $name =="
  if "$@"; then
    echo "  PASS"
    return 0
  fi
  local rc=$?
  echo
  echo "  FAIL: $name (exit $rc)" >&2
  return "$rc"
}

# Language detection: Rust workspace
if [[ -f Cargo.toml ]]; then
  echo "== pre-push-gates: $WORKTREE  (rust workspace) =="

  # Apply fmt first (writes changes), then verify with --check (no-op
  # when apply succeeded; non-zero only on rustfmt internal trouble).
  # The wizard's next git commit picks up any reformat-induced changes.
  run_gate "cargo fmt --all (apply)" \
    cargo fmt --all || exit 1
  run_gate "cargo fmt --all -- --check (verify)" \
    cargo fmt --all -- --check || exit 1

  run_gate "cargo clippy --workspace --all-targets --locked -- -D warnings" \
    cargo clippy --workspace --all-targets --locked -- -D warnings || exit 1

  run_gate "cargo build --workspace --locked --all-targets" \
    cargo build --workspace --locked --all-targets || exit 1

  run_gate "cargo test --workspace --locked" \
    cargo test --workspace --locked || exit 1

  echo
  echo "== all gates passed =="
  exit 0
fi

# No language-specific gates detected. Wizards in non-Rust workspaces
# can add their own runs above this exit; the prompt-side instruction
# leaves that slot open.
echo "pre-push-gates: no Cargo.toml at $WORKTREE — no language-specific gates to run"
exit 0
