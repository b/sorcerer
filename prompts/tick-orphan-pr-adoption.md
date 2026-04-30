# Orphan-PR adoption (for PRs whose owning wizard was pruned)

`discover_pr_set` only helps wizards that are *still* in `active_wizards` but went stale. It does NOT help when the wizard's `active_wizards` entry has been removed entirely — by an operator who manually edited `sorcerer.json`, by a state-file rewrite that dropped completed/failed entries before the PR was reviewed, by a crash that killed the entry write *between* opening the PR and persisting the entry, etc. In those cases the PR sits open on GitHub but is invisible to the tick: step 12 iterates `active_wizards` and finds nothing for that PR, so the merge gate never runs.

The fix is to scan GitHub once per tick for **open bot-authored PRs on configured repos that no `active_wizards` entry claims**, and synthesize an `awaiting-review` entry so step 12 picks them up on its own terms.

**Helpers** (extracted; the tick invokes these via Bash):

- `bash $SORCERER_REPO/scripts/discover-orphan-prs.sh <bot_author> [project_root]`
  - Prints zero or more JSON lines on stdout, one per orphan PR:
    `{"repo":"<owner/name>","pr_url":"...","branch":"...","head_sha":"...","issue_key":"<SOR-N|null>"}`
  - Filters out wip/<uuid> branches and any branch/URL already claimed by an active_wizards entry.
  - Always exits 0.
- `bash $SORCERER_REPO/scripts/adopt-orphan-pr.sh <orphan_json> [project_root]`
  - Creates `.sorcerer/wizards/<wid>/` scaffold, attempts worktree materialization from the bare clone, writes `pr_urls.json`, appends a `pr-orphan-adopted` event, prints the synthesized `active_wizards` entry to stdout.
  - Worktree failure is non-fatal: the entry is written with empty `worktree_paths` and the step 12 gate falls back to GitHub-API reads.

The adopted entry carries an `orphan_adopted: true` field. Step 12's stage 6.1 (gather full review materials) MUST check this field and:
- Skip the `mcp__plugin_linear_linear__get_issue` call when `issue_linear_id` is null, and note "orphan-adopted PR — no Linear issue context" in the evidence.
- When `worktree_paths[repo]` is empty for any repo, fall back to `gh api repos/<repo>/contents/<path>?ref=<head_sha>` for cited code reads. The diff (`gh pr diff`) is still authoritative for what changed; only the post-PR full-file reads need the fallback.

**This procedure is only applicable to PRs that look like sorcerer wizard output.** Filtering on bot author + branch-pattern (excluding `wip/<uuid>` WIP-preservation branches) is the gate; operator-pushed PRs under the bot identity should not be adopted automatically. If a false adoption happens anyway, an operator can apply a `no-adopt` label to the PR and amend `scripts/discover-orphan-prs.sh` to skip labeled PRs (not implemented today — add `--label '!no-adopt'` to the script's `gh pr list` invocation when this becomes a real failure mode).

## Step 11d imperative procedure (the every-tick loop)

Run on every tick — Step 11d is mandatory. The two helpers ship with sorcerer's tooling; you can run them yourself any time via the Bash tool to confirm they exist. Do not emit `skipped step-11d-orphan-adoption — not yet implemented (helpers absent)` or any equivalent. If discovery returns empty, that's the success path: log `tick: step-11d — 0 open PRs unclaimed, no orphan adoption` and return to step 12.

1. **Determine the bot author** — the GitHub App user that opens sorcerer-bot PRs. Run `gh api user --jq .login` (the App's `gh` auth identity); typical output is `sorcerer-b3k[bot]` or similar. If `gh api user` fails (auth blip), abort step 11d for this tick with `tick: step-11d — gh api user failed, deferring` and proceed to step 12.

2. **Run the discovery script.** Capture its output:
   ```bash
   orphan_lines=$(bash "$SORCERER_REPO/scripts/discover-orphan-prs.sh" "<bot-author>")
   ```
   The script prints zero or more JSON lines on stdout, one per orphan PR (shape: `{"repo","pr_url","branch","head_sha","issue_key"}`). If `$orphan_lines` is empty, log `tick: step-11d — 0 open PRs unclaimed, no orphan adoption` and skip the rest of this step.

3. **Cap at 5 adoptions per tick.** If `discover-orphan-prs.sh` produced more than 5 lines, take the first 5 (already sorted by repo then branch for determinism), log `tick: step-11d — deferred N orphan-PR adoptions to next tick (per-tick cap)`, and process only those 5 in step 4 below. The cap bounds accidental floods.

4. **For each orphan-PR JSON line**, call the adoption script and merge its result into `sorcerer.json`:
   ```bash
   new_entry=$(bash "$SORCERER_REPO/scripts/adopt-orphan-pr.sh" "$orphan_json")
   tmpf=$(mktemp)
   jq --argjson entry "$new_entry" '.active_wizards += [$entry]' .sorcerer/sorcerer.json > "$tmpf"
   mv "$tmpf" .sorcerer/sorcerer.json
   ```
   The script handles the heavy lifting: scaffolds the wizard's state dir, attempts worktree materialization from the bare clone, writes `pr_urls.json`, appends a `pr-orphan-adopted` event to `events.log`, and prints the synthesized `active_wizards` entry to stdout. Worktree failure is non-fatal — if `worktree_paths` ends up `{}` for the entry, step 12's stage 6.1 falls back to `gh api repos/.../contents?ref=<sha>` reads.

   Log per adoption: `tick: step-11d — adopted orphan PR <pr_url> as wizard <wid> (issue <SOR-N or "?">, branch <branch>)`.

5. **Adopted entries flow into step 12 on the SAME tick.** Once `.active_wizards` has been updated, step 12's `for each active_wizards entry with mode: implement and status: awaiting-review` loop will see them. There's no need to defer adoption to the next tick.

The `orphan_adopted: true` flag on synthesized entries is informational only at this layer; step 12's stage 6.1 reads it to decide on the Linear-fetch skip and worktree-fallback paths.
