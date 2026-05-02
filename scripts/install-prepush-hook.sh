#!/usr/bin/env bash
# install-prepush-hook.sh
#
# Install a sorcerer pre-push hook into a wizard's worktree. The hook
# runs $SORCERER_REPO/scripts/pre-push-gates.sh; non-zero exit blocks
# the push at the git protocol level. Wizards cannot accidentally
# bypass — only an explicit `git push --no-verify` skips, and wizard
# prompts forbid that flag.
#
# Why this exists: wizard prompts instruct `claude -p` sessions to run
# pre-push-gates.sh before pushing. In practice the LLM occasionally
# skips that step and pushes anyway, so CI catches issues that the
# local gate would have. Each slip burns an Opus refer-back cycle on
# something `cargo fmt --all` (or a one-line clippy fix) would have
# resolved for free. A git hook is the only way to enforce the gate
# at the protocol level.
#
# Usage:
#   bash $SORCERER_REPO/scripts/install-prepush-hook.sh <worktree-path>
#
# Exit:
#   0 — hook installed (or already present and identical).
#   1 — install failed (worktree missing, .git/hooks not writable, etc.).
#   2 — usage error.

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

# Resolve hooks dir for this worktree. `git rev-parse --git-path hooks`
# returns the per-worktree hooks dir under the bare clone's
# worktrees/<name>/hooks (or the main .git/hooks for the primary
# worktree). Per-worktree hooks are exactly what we want — only this
# worktree's pushes get gated, not other worktrees that share the bare.
HOOKS_DIR=$(git -C "$WORKTREE" rev-parse --git-path hooks 2>/dev/null)
if [[ -z "$HOOKS_DIR" ]]; then
  echo "ERROR: could not resolve hooks dir in $WORKTREE" >&2
  exit 1
fi
# git rev-parse may return a path relative to the worktree.
case "$HOOKS_DIR" in
  /*) ;;
  *)  HOOKS_DIR="$WORKTREE/$HOOKS_DIR" ;;
esac

mkdir -p "$HOOKS_DIR" || { echo "ERROR: cannot create $HOOKS_DIR" >&2; exit 1; }

HOOK_FILE="$HOOKS_DIR/pre-push"
cat > "$HOOK_FILE" <<'HOOK'
#!/usr/bin/env bash
# Sorcerer-installed pre-push hook. Runs the workspace pre-push gates
# (fmt apply+verify, clippy with -D warnings, build, tests for Rust
# workspaces). Non-zero exit blocks the push.
#
# Exemption: pushes whose only target refs are refs/heads/wip/* are
# allowed through unguarded. preserve-wizard-wip.sh uses this path to
# checkpoint a wizard's in-progress worktree under wip/<wizard-id> on
# crash; that path must succeed even when gates fail (the gate failure
# is often the reason the WIP needs preserving).
set -uo pipefail

# Read the refspec lines git provides on stdin. Each line:
#   <local_ref> <local_oid> <remote_ref> <remote_oid>
all_wip=1
saw_any=0
while IFS=' ' read -r _local_ref _local_oid remote_ref _remote_oid; do
  saw_any=1
  case "$remote_ref" in
    refs/heads/wip/*) ;;
    *) all_wip=0 ;;
  esac
done
if (( saw_any )) && (( all_wip )); then
  echo "[sorcerer pre-push] all refs are wip/*; skipping gates" >&2
  exit 0
fi

if [[ -z "${SORCERER_REPO:-}" ]]; then
  echo "[sorcerer pre-push] SORCERER_REPO env var unset; cannot locate pre-push-gates.sh — refusing push" >&2
  echo "  (set SORCERER_REPO in the wizard's env, or push with --no-verify if you absolutely must bypass)" >&2
  exit 1
fi
GATES="$SORCERER_REPO/scripts/pre-push-gates.sh"
if [[ ! -x "$GATES" ]]; then
  echo "[sorcerer pre-push] $GATES not executable; refusing push" >&2
  exit 1
fi

# Hooks run from the worktree root; pass it explicitly to the gates
# script (which auto-detects Rust vs other workspace shapes).
exec bash "$GATES" "$(pwd)"
HOOK

chmod +x "$HOOK_FILE" || { echo "ERROR: chmod +x $HOOK_FILE failed" >&2; exit 1; }

echo "installed pre-push hook at $HOOK_FILE"
exit 0
