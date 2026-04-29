#!/usr/bin/env bash
# Commit + force-push uncommitted worktree contents to wip/<wizard_id> on
# GitHub before a failed-state cleanup destroys them. Used during transitions
# to status: failed for implement/feedback/rebase wizards.
#
# Usage:
#   scripts/preserve-wizard-wip.sh <wizard_id> <issue_key> <worktree_path> <repo_slug>
#
# Args:
#   wizard_id       UUID of the wizard whose state is being preserved.
#   issue_key       Linear issue key for the commit message (or "-" if none).
#   worktree_path   Path to the wizard's worktree (must exist).
#   repo_slug       owner/name (NO github.com/ prefix).
#
# Side effects:
#   - Stages everything in the worktree (`git add -A`).
#   - Commits if there's anything to record (--no-verify; sorcerer identity).
#   - Force-pushes to wip/<wizard_id> on the named repo.
#
# Exit: 0 on push success, 1 on any failure (worktree missing, token mint
# failure, commit failure, push failure). Idempotent — safe to call twice.
set -euo pipefail

WIZARD_ID="${1:?usage: $0 <wizard_id> <issue_key> <worktree_path> <repo_slug>}"
ISSUE_KEY="${2:?usage: $0 <wizard_id> <issue_key> <worktree_path> <repo_slug>}"
WORKTREE="${3:?usage: $0 <wizard_id> <issue_key> <worktree_path> <repo_slug>}"
REPO_SLUG="${4:?usage: $0 <wizard_id> <issue_key> <worktree_path> <repo_slug>}"

[[ -d "$WORKTREE" ]] || exit 1

owner="${REPO_SLUG%/*}"
if ! out=$(GH_APP_INSTALLATION_ID= bash "$SORCERER_REPO/scripts/refresh-token.sh" \
      --installation-owner "$owner" 2>/dev/null); then
  exit 1
fi
eval "$out"

git -C "$WORKTREE" add -A 2>/dev/null || exit 1
if ! git -C "$WORKTREE" diff --cached --quiet 2>/dev/null; then
  git -C "$WORKTREE" \
      -c "user.email=sorcerer@noreply" \
      -c "user.name=sorcerer" \
      commit --no-verify \
      -m "WIP: ${WIZARD_ID} ${ISSUE_KEY} (auto-preserved on failed transition)" \
      >/dev/null 2>&1 || exit 1
fi

wip_branch="wip/${WIZARD_ID}"
git -C "$WORKTREE" push --force \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git" \
    "HEAD:refs/heads/${wip_branch}" >/dev/null 2>&1
