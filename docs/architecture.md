# Architecture

## Goals

Sorcerer turns a feature request into merged code without continuous human involvement. The system must:

- Decompose a request into an epic (or a set of sub-epics) with well-scoped issues in Linear before writing any code.
- **Operate across multiple repositories** within a single epic, a single sub-epic, or even a single issue — multi-repo is first-class, not bolt-on.
- Work issues in parallel or sequence depending on declared dependencies.
- Produce the right set of PRs per issue (one per affected repo), reviewed as a coherent unit against the issue's acceptance criteria.
- Recover from transient failures (rate limits, network errors, merge conflicts) without human help.
- Escalate to the user only for the situations enumerated in [`lifecycle.md`](lifecycle.md) § "User escalation".

## Non-goals

- Operating on repositories it has not been explicitly granted access to.
- Replacing human code review on high-risk paths — branch protection rules gate that.
- Monitoring post-merge production behaviour (rollbacks, regressions) — out of scope for v1.

## Stack

Sorcerer is prompts, scripts, and state files. No compiled codebase, no daemon, no service.

| Layer | Implementation |
|---|---|
| Coordinator | Detached bash loop (`scripts/coordinator-loop.sh`) running `claude -p` against `prompts/sorcerer-tick.md` repeatedly until no in-flight work remains |
| Architect sessions | One-shot `claude -p` subprocesses for Tier-1 planning (large requests) |
| Wizard sessions | Detached `claude -p` subprocesses, spawned per task (design / implement / feedback) |
| GitHub access | `gh` CLI reading `$GITHUB_TOKEN` on every invocation |
| Linear access | Linear MCP server (`mcp__plugin_linear_linear__*`) |
| Repo isolation | `git worktree` off a bare clone — one worktree per (issue × affected repo) |
| LLM | Claude, via the `claude` CLI |
| State | Plain JSON / JSONL files under `<project>/.sorcerer/`; `jq` + `uuidgen` do all serialization |

No Python. No SQLite. No Linear CLI. No GitHub MCP. State is JSON everywhere (`sorcerer.json`, `plan.json`, `manifest.json`, `meta.json`, `context.json`, `pr_urls.json`) and logs are JSONL (`events.log`, `escalations.log`); `jq` handles all reads and writes, so there's no YAML parser dependency. Linear goes over MCP because the plugin is already connected; GitHub goes over `gh` because the auth stack is a 1-hour App installation token refreshed out-of-band and that composes poorly with MCP's baked-Bearer-token config.

## Actors

### Coordinator (sorcerer)
One instance per user. Runs until stopped. Owns:
- The queue of incoming feature requests.
- The architect-plan roster and the wizard roster.
- PR-set review and merge authority.
- User escalation.

### Architect
A one-shot session for large/complex requests. Produces a durable design doc and a sub-epic plan. Does **not** create Linear issues directly — it delegates that to Tier-2 designers. See [`design-flow.md`](design-flow.md).

### Wizard
The identity that owns one Linear epic (one sub-epic, in Tier-1 flows). Not a running process — persists as `.sorcerer/wizards/<id>/`. Its work is done by short-lived wizard sessions, one per task (design, implement-an-issue, address-feedback).

An epic, and any individual issue in it, may span multiple repos.

### External systems
- **GitHub** — code hosting, PRs, merge gates.
- **Linear** — epic and issue tracking.
- **Anthropic API** — Claude models, via the `claude` CLI.

## Component layout

The sorcerer tool itself (this repo):
```
sorcerer/
├── prompts/
│   ├── sorcerer-tick.md              # coordinator tick prompt
│   ├── architect.md                  # Tier-1 architect prompt
│   ├── wizard-design.md              # Tier-2 designer prompt
│   ├── wizard-implement.md
│   ├── wizard-feedback.md
│   └── review-pr.md                  # PR-set review sub-prompt
├── scripts/
│   ├── coordinator-loop.sh           # detached loop running the tick
│   ├── start-coordinator.sh          # idempotent launcher
│   ├── stop-coordinator.sh           # graceful kill switch
│   ├── sorcerer-submit.sh            # /sorcerer dispatcher
│   ├── sorcerer-attach.sh            # live event stream
│   ├── spawn-wizard.sh
│   ├── ensure-bare-clones.sh
│   ├── refresh-token.sh              # mints a fresh GitHub App installation token
│   ├── format-event.sh               # jq-based event formatter
│   ├── install-skill.sh              # one-time setup
│   └── doctor.sh                     # preflight verification
├── config.json.example               # template for per-project config.json
└── docs/
```

Per-project runtime state (NOT in this repo — lives in each project sorcerer works on):
```
<project>/.sorcerer/
├── config.json                       # per-project config (auto-bootstrapped on first run)
├── sorcerer.json                     # coordinator's live state
├── events.log                        # append-only JSONL progress log
├── escalations.log                   # append-only JSONL escalations
├── coordinator.{pid,log}             # detached coordinator process state
├── requests/                         # queued request markdown files
├── architects/<id>/                  # Tier-1 outputs (design.md + plan.json)
├── wizards/<id>/                     # per-wizard state
└── repos/<owner>-<repo>.git/         # bare clones; one per repo in explorable_repos
```

Per-wizard state:
```
.sorcerer/wizards/<id>/
  context.json        # rewritten by coordinator before each spawn
  manifest.json       # written at end of design; epic id + issues with their `repos`
  heartbeat           # present while a session runs; absent between sessions
  logs/*.jsonl
  issues/<issue-id>/
    meta.json         # branch_name + {repo: pr_url} + merge_order + status
    trees/
      <owner>-<repoA>/   # worktree on <branch-name> off repoA
      <owner>-<repoB>/   # worktree on <branch-name> off repoB
      …                  # one per repo in the issue's repos list
```

## Data flow (happy path)

```
user        → sorcerer   : type `/sorcerer <prompt>` (writes .sorcerer/requests/<timestamp>.md, starts coordinator)
[large request: Tier 1]
sorcerer    → architect  : spawn (mode=architect); writes design.md + plan.json; exits
sorcerer    → wizard(s)  : spawn one designer per sub-epic in parallel
[per wizard, independently]
sorcerer    → wizard     : spawn (mode=design)
wizard      → Linear MCP : create Project (epic) + child Issues, each with `repos: [...]`
wizard      → state      : write manifest.json
[session exits]
sorcerer    → git        : for the next issue, create one worktree per repo in its list
sorcerer    → wizard     : spawn (mode=implement)
wizard      → Claude     : work across trees/<repo>/ per /wizard skill
wizard      → gh         : git push + gh pr create in EACH affected repo
wizard      → Linear MCP : transition issue to In Review
[session exits]
sorcerer    → Linear MCP : poll; sees In Review
sorcerer    → gh         : fetch ALL PRs in the issue; review as a coherent set
sorcerer    → Anthropic  : LLM review of the combined diff vs Linear acceptance criteria
decision    = merge
sorcerer    → gh         : serial merge per merge_order, or all-auto
GitHub      → sorcerer   : polled; each PR merged
sorcerer    → git        : remove ALL per-issue worktrees; delete local branches
sorcerer    → Linear MCP : transition issue to Done
[loop until all issues Done]
sorcerer    → Linear MCP : close the epic
```

## Multi-repo coordination

Sorcerer treats every issue as potentially multi-repo. Core rules:

- **One branch name per issue, reused across every affected repo.** The Linear convention (`<initials>/<team>-<num>-<slug>`) is globally unique, so collisions don't happen. Uniform naming makes cross-repo mental mapping trivial and lets Linear auto-link every sibling PR to the same issue.
- **One PR per affected repo.** Each PR's body contains `Part of <TEAM-NUM>` (not `Closes`). Linear links without auto-closing; sorcerer explicitly closes the issue after every PR merges.
- **Review is per-issue, not per-PR.** The coordinator waits for the full PR set to be ready, fetches all of them, and reviews as a coherent change. A merge decision applies to the set; a refer-back can reference cross-PR consistency.
- **Merge ordering.** When `meta.json` declares `merge_order`, sorcerer merges serially, each prior merge as a prereq. Otherwise it enables auto-merge on every PR simultaneously and lets each repo's CI decide timing.
- **Sibling-CI breakage.** If PR A merges and PR B's CI then fails because of A's change, sorcerer refers B back — a normal refer-back, not an escalation. Partial-merge state (serial-order step N fails after 1..N-1 merged) **is** an escalation; only a human can decide rollback vs. forward-fix.
- **Cross-sub-epic dependencies.** `depends_on` in a Linear issue's description may reference issues in sibling sub-epics, but only within the architect plan's declared cross-sub-epic contracts. A Tier-2 designer introducing a previously-unforeseen cross-epic dependency must escalate rather than declare it on its own.

## State model

### In Linear
- **Project** = epic. Owned by one wizard. Named from the feature request or sub-epic mandate.
- **Issue** = atomic unit of work. Description lists acceptance criteria, `repos: [...]`, optional `merge_order`, optional `depends_on`.
- **Label** `wizard:<id>` tags wizard-authored work.
- **Status transitions**: `Backlog` → `In Progress` → `In Review` → `Done`. Sorcerer sets `Done` only after every PR for the issue has merged.

### In GitHub
- One branch per issue, same name across every affected repo.
- One PR per affected repo; body: `Part of <TEAM-NUM>`.
- Label `wizard` on every PR (plus optional `wizard:<id>`).

### Locally
Plain files per "Component layout" above. State is recoverable: if `state/` is wiped, sorcerer rebuilds by listing Linear projects labelled `wizard:*` and GitHub PRs matching the wizard branch convention across every repo in `explorable_repos`.

## Process model

### Coordinator
A detached bash loop (`scripts/coordinator-loop.sh`) that runs the tick prompt repeatedly via `claude -p`. Started by `scripts/start-coordinator.sh` (which the `/sorcerer` skill calls; idempotent — only spawns a fresh loop when no live coordinator pid exists).

- Each tick is one `claude -p` invocation against `prompts/sorcerer-tick.md`. The session reads state, polls Linear MCP + `gh`, decides actions, executes them, writes state back.
- Loop sleep interval: 30s while any wizard or architect is `running`, 60s otherwise.
- The loop **self-exits** when `.sorcerer/sorcerer.json` has no entries with status `pending-architect`, `running`, or `pending-design` (and `.sorcerer/requests/` is empty). The `/sorcerer` skill spawns a fresh loop the next time a request arrives.
- Tick logic: reconcile state → refresh token if <10min → drain requests (route to architect or designer by size heuristic) → spawn architect sessions → process architect outputs → spawn designer / implement / feedback sessions → heartbeats → PR-set reviews → merge/refer-back/escalate → cleanup → persist.
- Idempotent.

`scripts/stop-coordinator.sh` is the kill switch — graceful SIGTERM with SIGKILL fallback after 10s, removes the pid file regardless.

### Wizard / architect session
```
SORCERER_CONTEXT_FILE=.sorcerer/<architects|wizards>/<id>/context.json \
  claude -p "/wizard (sorcerer-managed mode)" \
  --session-id <id>-<seq> \
  --cwd <working-dir>
```

`<working-dir>`:
- **architect**: `.sorcerer/architects/<id>/`.
- **design**: `.sorcerer/wizards/<id>/`.
- **implement / feedback**: `.sorcerer/wizards/<id>/issues/<issue-id>/` (parent of `trees/`). The session `cd`s into `trees/<owner>-<repo>/` for per-repo work.

The coordinator rewrites `context.json` before each spawn. Schema in [`SORCERER.md`](../../../.claude/skills/wizard/SORCERER.md).

Heartbeats every 60s. Stale >5min → respawn once; second failure → escalate.

## Failure modes and recovery

| Failure | Detection | Recovery |
|---|---|---|
| Wizard session crash | Tick-step-5 check: `kill -0 <pid>` fails. The pid liveness check runs before heartbeat staleness so crashes are caught within one tick (~30s), not after the 5-minute heartbeat window. Classification: OK marker → awaiting-review; FAILED marker → escalate; 429 → throttled; no marker → `discover_pr_set` runs against GitHub for `mode: implement|feedback|rebase` wizards — if every repo's branch already has an open PR, `status: awaiting-review` (work was durable even though the wizard crashed); otherwise respawn once, then escalate with `rule: <mode>-no-output`. | Recover-if-PRs-exist → respawn once → escalate. |
| Wizard stuck (no crash, but heartbeat stops advancing) | Tick step 11: heartbeat mtime > 5 minutes | PR-set recovery check first (same `discover_pr_set` path); otherwise respawn once; second failure → escalate. |
| Claude API rate limit | HTTP 429 in wizard log | Coordinator marks the wizard `throttled` (not `failed`), records `retry_after` (now+5min), respawns automatically on the next tick past that timestamp. After the 3rd throttle for the same entry, escalate with `rule: persistent-throttle`. 3+ throttles in one tick trigger a coordinator-level 15-minute pause via `paused_until` in `sorcerer.json`; `scripts/coordinator-loop.sh` honors it. |
| GitHub API rate limit | `gh` non-zero | Backoff; >1hr → escalate |
| `$GITHUB_TOKEN` expired | `gh api /user` 401 | `refresh-token.sh`; failure → escalate |
| Linear MCP disconnected | MCP error | Retry; persistent → escalate |
| Merge conflict on any PR | `gh pr merge` fails | Next feedback session rebases onto target in that repo, re-runs tests, re-pushes. Semantic conflicts past one retry → escalate |
| Sibling PR merge breaks this repo's CI | Re-queued PR turns red | Refer back — wizard fixes and re-pushes in the affected repo |
| Partial merge of serial PR set | Step N failed after 1..N-1 merged | Escalate — only a human decides rollback vs. forward-fix |
| Refer-back cap reached | Counter | Escalate with PR-set summary + attempt history |
| Branch protection blocks merge | `gh pr merge` 422 | Escalate |
| Two issues touch overlapping files in same repo | Conflict on second PR's open | Coordinator serializes: second wizard waits, rebases after first merge |
| Disk full | Write errors | Halt new spawns; escalate |

## Security model

### Blast radius
Sorcerer can write to every repo its App installation reaches, every Linear team its MCP-connected user belongs to, all of `state/` and `repos/`, and arbitrary subprocesses on the host.

Mitigations, priority order:

1. **Branch protection on every repo in `repos`.** GitHub refuses out-of-rule merges. Primary safety.
2. **Two-tier repo allowlist — code-enforced.** `repos` (mergeable targets) vs. `explorable_repos` (readable during design; superset). Three layers of enforcement:
   - Tick step 9 (`prompts/sorcerer-tick.md`) refuses to spawn an implement wizard when any entry in `issue.repos` is not in `config.repos` — emits an escalation with `rule: issue-repos-outside-allowlist` instead.
   - `scripts/ensure-bare-clones.sh` (the universal bottleneck for every worktree-hosted push) refuses to clone any spec not in `config.explorable_repos`, so even if the tick guard is bypassed, no writable checkout ever materializes for an out-of-allowlist repo.
   - GitHub App installation is scoped to the repos in `explorable_repos`; a push to any other repo fails at `gh` layer regardless.
3. **Scoped GitHub App installation.** App installed only on repos in `explorable_repos`.
4. **Scoped Linear user.** The MCP-connected user is invited only to relevant teams.
5. **Secret hygiene.** `.env` and minted token files gitignored; logs redact Bearer tokens; no tokens in process argv.
6. **Kill switch.** `scripts/stop.sh` halts all sessions, removes worktrees, leaves branches and PRs for inspection.

### Credentials at rest
- `$GITHUB_TOKEN` — minted by `scripts/refresh-token.sh`, sourced into the coordinator shell, inherited by spawned sessions.
- GitHub App private key — at `$GH_APP_PRIVATE_KEY_PATH`, mode 600.
- Linear MCP credentials — Claude Code plugin config.
- Anthropic API key — `~/.claude` or `$ANTHROPIC_API_KEY`.

## Cost and rate

LLM usage concentrates at:

1. **Architect** — one heavy Tier-1 session per complex request. Opus.
2. **Designer** — one session per sub-epic (≥1 per request). Opus.
3. **Executor** — per-issue work (often multiple repos per session). Sonnet default; Opus for hard issues.
4. **Reviewer** — per PR-set review. Opus — judgment-heavy.
5. **Coordinator ticks** — frequent, mostly deterministic. Sonnet or Haiku.

Tunables (see [`setup.md`](setup.md)):
- `models.coordinator`, `models.architect`, `models.designer`, `models.executor`, `models.reviewer`.
- `limits.max_concurrent_wizards`.
- `architect.auto_threshold` — when to auto-invoke Tier 1.

## Open questions

1. **Architect revision.** If a Tier-1 plan is wrong mid-flight, is re-running Tier 1 autonomous or user-approved? Current bias: user-approved.
2. **Cross-sub-epic implement-time coordination.** Today, sub-epic wizards run independently and conflicts surface at PR time. A shared lock/reservation system could serialize at implement time.
3. **Post-merge regression.** Should sorcerer watch main-branch CI and auto-revert PRs that break it?
4. **Unattended operation.** `/loop` dies with the terminal. True unattended operation wants `tmux`/`systemd` wrapping — out of scope for v1.
