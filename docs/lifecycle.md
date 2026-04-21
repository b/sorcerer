# Lifecycle

What sorcerer does, step by step, with decision rules and escalation criteria. Multi-repo is assumed throughout; single-repo is the degenerate case.

## Terminology

- **Coordinator** — the Claude Code `/loop` session that is sorcerer itself.
- **Architect** — a one-shot Tier-1 session for large/complex requests. Produces a design doc and sub-epic plan. See [`design-flow.md`](design-flow.md).
- **Wizard** — the identity that owns one Linear epic (or sub-epic). Persists as `.sorcerer/wizards/<id>/`. Not a running process.
- **Wizard session** — a single `claude -p` invocation doing one task for a wizard (design, implement-an-issue, address-feedback). Short-lived.

## Sorcerer tick

One iteration of the coordinator loop. Default pacing: 30s with active work, 5min idle.

1. **Reconcile state.** Read `.sorcerer/sorcerer.json`, every `.sorcerer/wizards/*/manifest.json`, every `.sorcerer/architects/*/plan.json`.
2. **Refresh `$GITHUB_TOKEN` if stale.** <10min remaining → invoke `refresh-token.sh`, update coordinator env. Spawned sessions inherit the fresh token.
3. **Drain the request queue.** Each file in `.sorcerer/requests/`: pick the tier.
   - Large / complex (per `architect.auto_threshold`, or `scale: large` in the request) → move to `.sorcerer/architects/<id>/request.md`, write `context.json` with `"mode": "architect"`, status `pending-architect`.
   - Otherwise → move to `.sorcerer/wizards/<id>/request.md`, `"mode": "design"`, status `pending-design`.
4. **Spawn architect sessions** for every `pending-architect` run. One at a time if `limits.max_concurrent_wizards == 1`.
5. **Process architect outputs.** For every architect run whose `plan.json` is written and heartbeat absent: read `plan.json`; for each sub-epic in it, create a new wizard (`.sorcerer/wizards/<id>/`) with `mode: design`, `scope` = the sub-epic mandate, `architect_plan_file` pointing at the plan. Status `pending-design`.
6. **Spawn designer wizard sessions** for every `pending-design` wizard whose cross-epic deps are satisfied. A sub-epic with `depends_on: [X, Y]` waits until every issue in sub-epic X's and Y's manifests has merged (or been archived). Strict gate: no parallel design across dependent sub-epics. Sub-epics with no deps spawn as concurrency allows.
7. **Poll Linear** for every active wizard's epic (`mcp__plugin_linear_linear__list_issues` filtered by project). Detect:
   - Issues newly `In Review` with no pending review → queue for step 11.
   - All children `Done` → mark wizard `cleanup`.
8. **Decide next issue actions.** For each wizard whose epic has unblocked issues not yet in progress: select by (a) fewest unsatisfied deps, (b) smallest size. Respect cross-sub-epic `depends_on`. Obey `limits.max_concurrent_wizards`.
9. **Prepare worktrees** for every scheduled `implement` session. One worktree per repo in the issue's `repos` list (see "Worktree setup" below).
10. **Spawn implement / feedback sessions** for scheduled tasks.
11. **Check heartbeats.** Every active session's `heartbeat` file older than 5min → `stale`. Respawn once; second failure → `failed` → escalate.
12. **Review ready PR sets.** For each queued issue review:
    - Fetch the full set from the issue's `pr_urls` map. For each: `gh pr view <url> --json state,mergeable,statusCheckRollup,reviews,comments,files,body`.
    - Defer to the next tick if any PR is still draft or has no checks yet. An issue review requires the complete set.
    - **CI gate**: every required check green on every PR.
    - **Bot gate**: all automated-reviewer findings resolved across every PR.
    - **LLM gate**: fetch the Linear issue (`get_issue`); invoke `review-pr.md` with the combined diff + criteria + per-PR check status. Outcome: `merge` / `refer-back` / `escalate`.
    - Act (see § "PR set review decision").
13. **Clean up merged issues.** For each issue whose full PR set merged this tick, the coordinator (not a wizard) runs per repo:
    - `git -C repos/<owner>-<repo>.git worktree remove .sorcerer/wizards/<id>/issues/<issue-id>/trees/<owner>-<repo>`
    - `git -C repos/<owner>-<repo>.git branch -d <branch-name>`
    - Delete `trees/<owner>-<repo>/` on disk; retain `meta.json`.

    - Once every repo is cleaned: transition the Linear issue to `Done` (idempotent with the Linear-GitHub integration).
14. **Clean up completed wizards.** `cleanup` wizards: verify every worktree/branch is gone in every repo touched, close the Linear epic via MCP, transition to `done`. After 7 days, delete the wizard state dir.
15. **Persist.** Write `.sorcerer/sorcerer.json`, append to `events.log`. End tick.

Ticks are idempotent.

## Worktree setup

Before every `implement` session (and before the first `feedback` session, though typically the worktrees already exist by then), for each `<owner>/<repo>` in the issue's `repos` list:

```
git -C repos/<owner>-<repo>.git worktree add \
  ../../.sorcerer/wizards/<id>/issues/<issue-id>/trees/<owner>-<repo> \
  -b <branch-name> \
  origin/<default-branch>
```

`<branch-name>` is one name for the whole issue, reused across every repo. It follows Linear's `<initials>/<team>-<num>-<slug>` convention so Linear's GitHub integration auto-links every PR.

For `feedback` sessions, worktrees pre-exist; the coordinator skips `worktree add`.

Bare clones (one per repo in `explorable_repos`) are a hard precondition. `scripts/doctor.sh` verifies.

## Wizard session spawn

```
SORCERER_CONTEXT_FILE=.sorcerer/wizards/<id>/context.json \
  claude -p "/wizard (sorcerer-managed mode)" \
  --session-id <wizard-id>-<seq> \
  --cwd <working-dir>
```

The coordinator rewrites `context.json` with the task's fields before each spawn. Schema in [`SORCERER.md`](../../../.claude/skills/wizard/SORCERER.md).

`<working-dir>`:
- **design**: `.sorcerer/wizards/<id>/`.
- **implement / feedback**: `.sorcerer/wizards/<id>/issues/<issue-id>/` (the issue dir; the session `cd`s into `trees/<repo>/` per repo).

Token inheritance: `$GITHUB_TOKEN` from coordinator env.

## Architect session spawn

```
SORCERER_CONTEXT_FILE=.sorcerer/architects/<id>/context.json \
  claude -p "/wizard (sorcerer-managed mode)" \
  --session-id arch-<id> \
  --cwd .sorcerer/architects/<id>
```

Same schema mechanism; `mode: architect` in the context. Output files: `design.md` and `plan.json` in the architect's state dir.

## Wizard lifecycle

### Design (one session per wizard)
`mode: design`. First spawn. May be spawned directly from a user request (no architect) or from an architect plan (sub-epic designer — `scope` and `architect_plan_file` set).

1. Read `context.json` and the mandate (`request_file`, or if `architect_plan_file` present, read the sub-epic's mandate from the plan plus the architect's `design.md`).
2. For every repo in `explorable_repos`, check out the default branch from the bare clone into a scratch dir; read `CLAUDE.md` and `docs/`.
3. `SKILL.md` Phase 2 across the relevant repos.
4. Decompose into issues. Each issue specifies:
   - Atomically-mergeable acceptance criteria.
   - `repos: [...]` — every repo the issue touches (≥1, subset of this wizard's `repos`).
   - Optional `merge_order: [...]` — subset of `repos` declaring required serial merge order (e.g. protos before service).
   - Optional `depends_on: [...]` — other Linear issues (within this epic, or from sibling sub-epics if the architect plan declared cross-epic contracts) that must merge first.
5. Create the Linear project: `mcp__plugin_linear_linear__save_project`.
6. For each issue: `mcp__plugin_linear_linear__save_issue` with label `wizard:<id>`.
7. Write `manifest.json`:
   ```json
   {
     "epic_linear_id": "<id>",
     "issues": [
       {
         "linear_id": "<id>",
         "issue_key": "<TEAM-NUM>",
         "repos": ["<owner/repo>"],
         "merge_order": ["<owner/repo>"],
         "depends_on": ["<linear id or issue key>"]
       }
     ]
   }
   ```
   `merge_order` and `depends_on` are optional (omit or use `[]` when not applicable). `depends_on` may cross sub-epics per the architect plan.
8. Remove heartbeat. Exit.

### Implement (one session per issue, first attempt)
`mode: implement`. Worktrees pre-created for every repo in `repos`.

1. Read `context.json` (includes `worktree_paths: {repo: path}`, `merge_order` if declared).
2. Fetch the Linear issue; parse acceptance criteria and repos.
3. Transition issue to `In Progress`.
4. `SKILL.md` Phases 1–7 across the affected repos — `cd` between `trees/<repo>/` subdirs as needed. Run each repo's tests in its own tree with its own toolchain.
5. Phase 8, per repo (in `merge_order` if declared, otherwise any order):
   - `cd trees/<owner>-<repo>`.
   - `git push -u origin <branch-name>`.
   - `gh pr create --title "..." --body "<body including 'Part of ISSUE-KEY'>"`.
   - Resolve bot findings on the PR (`SKILL.md` Phase 8).
6. After every repo has a clean PR, transition the Linear issue to `In Review`.
7. Remove heartbeat. Exit.

### Feedback (one session per refer-back cycle)
`mode: feedback`. Worktrees and PRs exist. Coordinator posted a structured review on the primary PR and mirrored a pointer on siblings. Linear issue moved back to `In Progress`.

1. Read `context.json` (includes `pr_urls: {repo: url}`, `refer_back_cycle`).
2. Fetch the primary review:
   ```
   gh pr view <primary_pr_url> --json comments,reviews,files,statusCheckRollup
   ```
   Also fetch checks on every sibling PR:
   ```
   for repo in <repos>; do gh pr checks "${pr_urls[$repo]}"; done
   ```
3. Aggregate concerns across the set.
4. Per concern:
   - Valid → fix it in the appropriate repo's tree. TDD applies to behavioural concerns.
   - False positive → reply on the specific PR where the concern was raised via `gh pr comment`.
5. Re-run tests in every affected repo per `SKILL.md` Phase 5.
6. Per affected repo: commit (message references concerns addressed), `git push` from that tree.
7. Transition the Linear issue back to `In Review`.
8. Remove heartbeat. Exit.

**Hard cap**: `refer_back_cycle == max_refer_back_cycles` with unresolved concerns → escalate, don't push again.

### Epic completion
When every child issue is `Done`:

1. Summary comment on the Linear epic (`save_comment`): what shipped, deferred follow-ups, any cross-epic implications.
2. Mark project completed.
3. Wizard → `done`. State dir retained 7 days for audit, then removed.

## PR set review decision

One decision per issue.

### `merge`
All of:
- CI green on every PR in the set.
- All bot findings resolved across every PR.
- LLM review: acceptance criteria met, no high-severity concerns, no cross-PR consistency issues.
- No merge conflicts anywhere in the set.

**Action:**
- With `merge_order` declared: serial. Merge PR 1, wait for confirmation; merge PR 2; etc. `gh pr merge <url> --squash --delete-branch` each. On failure of step N, stop — leave 1..N-1 merged and escalate (partial-merge state needs a human).
- Without `merge_order`: enable auto-merge on every PR simultaneously. `gh pr merge <url> --auto --squash --delete-branch`. GitHub's own queue decides timing.

Per-issue cleanup runs once the full set has merged.

### `refer-back`
Any gate fails but nothing escalation-worthy. Coordinator posts a structured review comment on the **primary PR** (first in `repos`, or the one with the most lines changed if unclear) summarising:
- Which PRs failed which gates.
- Specific LLM feedback, keyed to `(repo, file, line)` where possible.
- A concrete next step for the wizard.

On every sibling PR, mirror a short pointer: "See <primary-pr-url> for review."

**Action:** transition the Linear issue back to `In Progress`. Next tick spawns a `feedback` session with the full `pr_urls` map in context.

### `escalate`
Any of:
- `refer_back_cycle >= max_refer_back_cycles` with concerns remaining.
- LLM review returns `severity: high` + category `security` anywhere in the set.
- `gh pr merge` returns 422 on any PR with every required check green.
- Partial serial merge — steps 1..N-1 merged, step N failed.

**Action:** escalation record; wizard `blocked` on this issue. Other issues (and other wizards) continue.

## User escalation

Strict list. Anything not on it is handled autonomously.

1. **Invalid credentials.** `gh api /user` 401 *and* `refresh-token.sh` cannot mint a replacement. Or persistent Linear MCP auth errors.
2. **API quota exhausted past backoff** — >1hr.
3. **Branch protection blocks merge** — 422 with every required check green.
4. **Refer-back cap reached** — concerns remain at `max_refer_back_cycles`.
5. **Security-flagged diff** — LLM reviewer `severity: high`, category `security`.
6. **Destructive operation required** — force-push, history rewrite, non-pre-authorized migration.
7. **Host resource exhaustion.**
8. **Conflicting concurrent work** — a sibling merge (possibly in another sub-epic) invalidates this issue's design. Distinct from a sibling CI break, which is a refer-back.
9. **Partial serial merge** — steps 1..N-1 merged, step N failed; human decides rollback vs. forward-fix.
10. **Architect plan invalid mid-flight** — a sub-epic designer escalates because its mandate is impossible or inconsistent; sorcerer does not autonomously re-run Tier 1.

Everything else — transient errors, rebasable conflicts, flaky tests on retry, first-pass CI failures, bot false positives, single-cycle refer-backs, sibling-CI breakage — autonomous.

## Escalation mechanism

- **Preferred**: `PushNotification` to the coordinator's session.
- **Always**: append one JSONL record per escalation to `.sorcerer/escalations.log`:

```json
{
  "ts": "<ISO-8601>",
  "wizard_id": "<uuid or architect id>",
  "mode": "architect | design | implement | feedback | coordinator",
  "issue_key": "<TEAM-NUM or null>",
  "pr_urls": {"<owner/repo>": "<url>"},
  "rule": "<one of the rules above>",
  "attempted": "<what sorcerer tried, chronologically; \\n for newlines>",
  "needs_from_user": "<specific action required to unblock; \\n for newlines>"
}
```

Use `jq -nc` to build each line (keeps special characters safe). `jq .` renders a record human-readably if you need to read one.

Users who want external delivery (Slack, email) point their tailer at `escalations.log`.
