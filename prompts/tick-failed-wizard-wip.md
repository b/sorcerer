# Failed-wizard WIP preservation (for implement / feedback / rebase wizards)

When PR-set recovery returns nothing and the entry is about to transition to `status: failed`, the wizard's worktree may still hold uncommitted work — the SOR-381 case: an implement that finished its diff in-tree but couldn't run the workspace gates (host disk full) and reported `IMPLEMENT_FAILED` without committing. The default cleanup path destroys that diff. This procedure preserves it as a `wip/<wizard-id>` branch on GitHub before any cleanup runs, so an operator (or a future re-spawn) can recover the work or audit what the wizard actually produced.

**MUST run on every transition to `status: failed`** for `mode in {implement, feedback, rebase}` BEFORE any cleanup or `status` write. Side-effects are best-effort (a push that fails for auth/network reasons shouldn't block the failed transition), but the attempt is mandatory — a wizard whose `wip_branch` field is missing on a failed entry MUST have had this procedure attempted.

**Helper:**

- `bash $SORCERER_REPO/scripts/preserve-wizard-wip.sh <wizard_id> <issue_key> <worktree_path> <repo_slug>`
  - Mints a token for the repo owner, stages the worktree (`git add -A`), commits any pending diff with the sorcerer identity, and force-pushes to `wip/<wizard_id>` on `<repo_slug>` (e.g. `etherpilot-ai/archers`).
  - Idempotent: if there's nothing new to commit, the script no-ops the commit step and still re-pushes the existing tip.
  - Exit 0 on push success, 1 on any failure (worktree missing, token mint failure, commit failure, push failure).

**Procedure** (called from each transition-to-failed site for implement/feedback/rebase wizards):

1. For each `(repo_slug, worktree_path)` in the entry's `repos` × `worktree_paths`:
   - Run `bash "$SORCERER_REPO/scripts/preserve-wizard-wip.sh" "<wizard_id>" "<issue_key>" "<worktree_path>" "<repo_slug>"`.
   - On exit 0: record `repo_slug` in a local `wip_pushed` array.
   - On exit non-zero: log `tick: wip-preserve failed for <wizard_id> on <repo_slug>; continuing` to stdout. Do NOT block the failed transition — degraded preservation is better than a hung tick.
2. Set `wip_branch: "wip/<wizard_id>"` on the entry (regardless of push success — operators looking at the entry know to check the branch).
3. Append to `.sorcerer/events.log`:
   ```json
   {"ts":"...","event":"wizard-wip-preserved","id":"<wizard-id>","issue_key":"<SOR-N>","mode":"<mode>","wip_branch":"wip/<wizard-id>","repos_pushed":["<repo_slug>",...],"repos_failed":["<repo_slug>",...]}
   ```
4. Then proceed with the existing `status: failed` write + escalation as the calling site already specifies.

This procedure is **only applicable to `mode: implement | feedback | rebase`** — architect / designer / reviewer wizards have no worktree to preserve.
