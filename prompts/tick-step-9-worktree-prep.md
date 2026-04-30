# Step 9 — Worktree prep for implement candidates

Read `config.json:limits.max_concurrent_wizards` (default 3). Count running entries. For each implement candidate from step 8, while running-count is below the cap:

**Pre-flight resource gate (run once at the top of step 9, before iterating candidates).** Spawning an implement wizard allocates a worktree (typically 100MB-300MB depending on repo) and the wizard's `cargo` (or equivalent) build can grow `target/` to 10-20GB. Disk exhaustion is the canonical SOR-381 failure mode — a wizard reports `IMPLEMENT_FAILED` because workspace gates can't write to disk, and now slice 55 has to WIP-preserve work that should never have been spawned in the first place. Pre-flight refuses to spawn when host resources are below floor. The gate is **disk + provider** today; memory-floor is structurally similar but harder to threshold meaningfully (cargo's RSS varies wildly by crate) and is left for a follow-up.

1. **Disk floor.** Read `config.json:limits.disk_floor_gb` (default `40`). Run `df -BG --output=avail "$PROJECT_ROOT" | tail -1 | tr -dc '0-9'` to get available GB. If `< disk_floor_gb`: do NOT spawn any candidates this tick. Append ONE escalation per tick (suppress duplicates by checking the most recent `escalations.log` line for `rule: spawn-deferred-disk-floor` from this tick):
   ```bash
   jq -nc \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg rule "spawn-deferred-disk-floor" \
     --argjson avail_gb <N> \
     --argjson floor_gb <FLOOR> \
     --argjson candidates_deferred <COUNT> \
     --arg attempted "Implement spawn deferred this tick: host has <N>G free, below floor <FLOOR>G. <COUNT> candidates queued." \
     --arg needs_from_user "Free disk (target/ caches, model weights, archived bare clones) or lower limits.disk_floor_gb in config.json. Coordinator will retry on the next tick once free space is above floor." \
     '{ts:$ts, wizard_id:null, mode:"coordinator", issue_key:null, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user, avail_gb:$avail_gb, floor_gb:$floor_gb, candidates_deferred:$candidates_deferred}' \
     >> .sorcerer/escalations.log
   ```
   Emit `tick: spawn deferred — disk <N>G < floor <FLOOR>G` to stdout and skip step 10 entirely. **Step 11 (heartbeat poll) and step 13 (cleanup) MUST still run** — running ticks free disk via merged-wizard cleanup, so blocking them would be self-defeating.

2. **Provider floor.** Sample `apply-provider-env.sh` indirectly: read `config.json:providers[].name` and `sorcerer.json:providers_state[<name>].throttled_until`. Count providers whose `throttled_until` is null/missing/in-the-past. If `0`: do NOT spawn any candidates this tick. Suppress duplicate escalations as above; emit `tick: spawn deferred — all providers throttled` and skip step 10.

3. **Concurrency floor (existing).** If `running_count >= max_concurrent_wizards`: skip step 10 entirely; current implements drain naturally before next spawn.

If all three floors pass, proceed to per-candidate processing below.

0. **Allowlist gate (hard fail, don't spawn).** Read `config.json:repos` into a set. For each entry in `issue.repos`, verify membership. If ANY of `issue.repos` is NOT in `config.repos`:
   - Do NOT create worktrees. Do NOT spawn. This is a design-layer contract violation (the designer or architect escaped the sub-epic scope).
   - Append one JSON line to `.sorcerer/escalations.log`:
     ```bash
     jq -nc \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg issue_key "<SOR-N>" \
       --arg designer_id "<designer wizard id>" \
       --arg rule "issue-repos-outside-allowlist" \
       --argjson offending '["<offending repo>"]' \
       --argjson allowed   '["<config.repos>"]' \
       --arg attempted "Issue requests repos that are not in config.json:repos; refusing to spawn implement wizard." \
       --arg needs_from_user "Either add the repo to config.json:repos (and the App must be installed on it), or reject this issue in Linear and have the designer re-emit." \
       '{ts:$ts, wizard_id:null, mode:"coordinator", issue_key:$issue_key, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user, designer_id:$designer_id, offending_repos:$offending, allowed_repos:$allowed}' \
       >> .sorcerer/escalations.log
     ```
   - Emit `tick: blocked <issue_key> — repos outside config.json:repos: <list>` to stdout.
   - Move on to the next candidate. Do NOT count this as a concurrency slot (no wizard was spawned).

1. Generate UUID: `uuidgen`. This is the implement wizard's id.
2. Compute the issue dir: `.sorcerer/wizards/<designer-id>/issues/<issue-key>/` (use `issue_key` like `SOR-11` — filesystem-safe).
3. `mkdir -p <state_dir>/logs <state_dir>/trees`.
4. Fetch Linear issue: `mcp__plugin_linear_linear__get_issue` with `id=<issue.linear_id>` to get `gitBranchName`. Capture as `branch_name`.
5. **Ensure bare clones exist** for every repo this issue touches. One call covers all of them; the script is idempotent, auto-mints per-owner tokens, and itself enforces `explorable_repos` — if step 0 somehow missed a violation, this is the second line of defense and will `exit 1` rather than clone an out-of-allowlist repo:
   ```bash
   bash scripts/ensure-bare-clones.sh <repo1> <repo2> ...
   ```
6. For each repo in `issue.repos`:
   - Compute the bare clone path: `repos/<owner>-<repo>.git` (slash → dash).
   - Compute the worktree path: `<state_dir>/trees/<owner>-<repo>` (also dash-converted).
   - Create the worktree:
     ```bash
     git -C <bare-clone-path> worktree add \
       <worktree-path> \
       -b <branch_name> \
       <default-branch-from-config-or-fetched-from-gh>
     ```
     Note: use the **local** branch ref (e.g. `main`), NOT `origin/main`. In a bare clone the default refspec `+refs/heads/*:refs/heads/*` updates `refs/heads/*` on every fetch but leaves `refs/remotes/origin/*` frozen at clone time. `origin/main` is therefore stale; the canonical tip lives at `refs/heads/main`. `ensure-bare-clones.sh` is responsible for fetching before this step so the local ref is fresh.
   - For default branch: read from `gh api repos/<owner>/<repo> -q .default_branch` once per repo (cache during this tick).
6. Write `<state_dir>/meta.json` with `jq -n` (never bash heredocs — keeps multi-word values safe):
   ```bash
   jq -n \
     --arg issue_linear_id "<Linear UUID>" \
     --arg issue_key       "<SOR-N>" \
     --arg branch_name     "<branch_name>" \
     --arg default_branch  "<main or whatever fetched>" \
     --argjson repos             '["<owner/repo>"]' \
     --argjson worktree_paths    '{"<owner/repo>":"<abs path>"}' \
     --argjson merge_order       '["<owner/repo>"]' \
     --arg designer_id     "<designer wizard id>" \
     --arg manifest_file   "<path to designer's manifest>" \
     '{
       issue_linear_id:$issue_linear_id,
       issue_key:$issue_key,
       branch_name:$branch_name,
       default_branch:$default_branch,
       repos:$repos,
       worktree_paths:$worktree_paths,
       merge_order:$merge_order,
       designer_id:$designer_id,
       manifest_file:$manifest_file
     }' > <state_dir>/meta.json
   ```
   Omit `merge_order` from the jq invocation entirely (both the `--argjson` flag and the field in the object) when the issue has no merge order.

If concurrency cap is hit: stop preparing more candidates; log `tick: concurrency-limit reached, deferring implement spawn for <issue_key>`. Remaining candidates wait for the next tick.
