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
| Coordinator | A Claude Code session driven by the `/loop` skill — one tick = one LLM turn |
| Architect sessions | One-shot `claude -p` subprocesses for Tier-1 planning (large requests) |
| Wizard sessions | Detached `claude -p` subprocesses, spawned per task (design / implement / feedback) |
| GitHub access | `gh` CLI reading `$GITHUB_TOKEN` on every invocation |
| Linear access | Linear MCP server (`mcp__plugin_linear_linear__*`) |
| Repo isolation | `git worktree` off a bare clone — one worktree per (issue × affected repo) |
| LLM | Claude, via the `claude` CLI |
| State | Plain YAML / JSONL files under `state/` |

No Python. No SQLite. No Linear CLI. No GitHub MCP. Linear goes over MCP because the plugin is already connected; GitHub goes over `gh` because the auth stack is a 1-hour App installation token refreshed out-of-band and that composes poorly with MCP's baked-Bearer-token config.

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
The identity that owns one Linear epic (one sub-epic, in Tier-1 flows). Not a running process — persists as `state/wizards/<id>/`. Its work is done by short-lived wizard sessions, one per task (design, implement-an-issue, address-feedback).

An epic, and any individual issue in it, may span multiple repos.

### External systems
- **GitHub** — code hosting, PRs, merge gates.
- **Linear** — epic and issue tracking.
- **Anthropic API** — Claude models, via the `claude` CLI.

## Component layout

```
sorcerer/
├── prompts/
│   ├── sorcerer-tick.md           # coordinator tick prompt
│   ├── architect.md               # Tier-1 architect prompt
│   ├── wizard-design.md           # Tier-2 designer prompt
│   ├── wizard-implement.md
│   ├── wizard-feedback.md
│   └── review-pr.md               # PR-set review sub-prompt
├── scripts/
│   ├── spawn-wizard.sh
│   ├── spawn-architect.sh
│   ├── refresh-token.sh           # mints a fresh GitHub App installation token
│   ├── cleanup-wizard.sh
│   ├── stop.sh                    # kill switch
│   └── doctor.sh                  # preflight verification
├── state/
│   ├── sorcerer.yaml
│   ├── requests/                  # drop feature request files here
│   ├── architects/<id>/           # Tier-1 outputs (design doc + plan)
│   ├── wizards/<id>/              # per-wizard state
│   ├── events.log
│   └── escalations.log
├── repos/                         # gitignored; bare clones of every repo in explorable_repos
│   └── <owner>-<repo>.git/
├── config.yaml                    # repos, explorable_repos, models, limits
└── docs/
```

Per-wizard state:
```
state/wizards/<id>/
  context.yaml        # rewritten by coordinator before each spawn
  manifest.yaml       # written at end of design; epic id + issues with their `repos`
  heartbeat           # present while a session runs; absent between sessions
  logs/*.jsonl
  issues/<issue-id>/
    meta.yaml         # branch_name + {repo: pr_url} + merge_order + status
    trees/
      <owner>-<repoA>/   # worktree on <branch-name> off repoA
      <owner>-<repoB>/   # worktree on <branch-name> off repoB
      …                  # one per repo in the issue's repos list
```

## Data flow (happy path)

```
user        → sorcerer   : drop feature request in state/requests/
[large request: Tier 1]
sorcerer    → architect  : spawn (mode=architect); writes design.md + plan.yaml; exits
sorcerer    → wizard(s)  : spawn one designer per sub-epic in parallel
[per wizard, independently]
sorcerer    → wizard     : spawn (mode=design)
wizard      → Linear MCP : create Project (epic) + child Issues, each with `repos: [...]`
wizard      → state      : write manifest.yaml
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
- **Merge ordering.** When `meta.yaml` declares `merge_order`, sorcerer merges serially, each prior merge as a prereq. Otherwise it enables auto-merge on every PR simultaneously and lets each repo's CI decide timing.
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
```
claude /loop 30s /sorcerer-tick
```
- One tick per LLM turn running `prompts/sorcerer-tick.md`.
- Tick: reconcile state → refresh token if <10min → drain requests (route to architect or designer by size heuristic) → spawn architect sessions → process architect outputs → spawn designer / implement / feedback sessions → heartbeats → PR-set reviews → merge/refer-back/escalate → cleanup → persist.
- Idempotent.

### Wizard / architect session
```
SORCERER_CONTEXT_FILE=state/<architects|wizards>/<id>/context.yaml \
  claude -p "/wizard (sorcerer-managed mode)" \
  --session-id <id>-<seq> \
  --cwd <working-dir>
```

`<working-dir>`:
- **architect**: `state/architects/<id>/`.
- **design**: `state/wizards/<id>/`.
- **implement / feedback**: `state/wizards/<id>/issues/<issue-id>/` (parent of `trees/`). The session `cd`s into `trees/<owner>-<repo>/` for per-repo work.

The coordinator rewrites `context.yaml` before each spawn. Schema in [`SORCERER.md`](../../../.claude/skills/wizard/SORCERER.md).

Heartbeats every 60s. Stale >5min → respawn once; second failure → escalate.

## Failure modes and recovery

| Failure | Detection | Recovery |
|---|---|---|
| Wizard session crash | Stale heartbeat | Respawn once; second failure → escalate |
| Claude API rate limit | HTTP 429 | Exponential backoff (base 30s, cap 15min) |
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
2. **Two-tier repo allowlist.** `repos` (mergeable targets) vs. `explorable_repos` (readable during design; superset). Issues can only declare `repos` from the `repos` list; a design that needs a currently-read-only repo escalates for human approval.
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
