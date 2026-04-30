# PR-set recovery (for implement / feedback / rebase wizards)

A wizard can do real work — push commits, open PRs — and then die before writing its completion marker or removing the heartbeat (crash, OOM, the claude subprocess itself hitting a limit mid-sentence, machine reboot, etc). The cheap-but-wrong move is to mark the entry `failed` and escalate. The right move is to check GitHub first: **if every repo in the wizard's `repos` has an open PR on its `branch_name`, the wizard's output is already durable — reconstruct `pr_urls.json` from `gh` and transition the entry to `awaiting-review`**. Step 12 will re-evaluate the set and do the appropriate next thing (merge / refer-back / rebase) on its own terms.

**Helper** (used in step 5c's "crashed without writing output" path and step 11c's stale-heartbeat respawn path):

- `bash $SORCERER_REPO/scripts/discover-pr-set.sh <branch_name> <repo1> [<repo2> ...]`
  - On success (every named repo has an open PR for `<branch_name>`): prints `{"<owner/name>": "<pr_url>", ...}` JSON to stdout, exits 0.
  - On any missing PR (incomplete set): prints nothing, exits 1.
  - Repos are passed in `github.com/owner/name` form (the prefix is stripped internally).

**Recovery action** (when discover-pr-set succeeded — write pr_urls.json, transition to awaiting-review, append event):

```bash
echo "$pr_set_json" > "$state_dir/pr_urls.json"
# Update the entry: status=awaiting-review, pr_urls=<pr_set_json>
printf '{"ts":"%s","event":"pr-set-recovered","id":"%s","issue_key":"%s","pr_count":%d,"source":"<step5|step11>"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wizard_id" "$issue_key" "$pr_count" >> .sorcerer/events.log
```

This is only applicable to `mode: implement | feedback | rebase` wizards — the ones that have `branch_name` + `repos` + `state_dir` fields. Architect and designer wizards produce plan/manifest files locally and don't have a PR fallback, so they stay on the original failed/respawn path.
