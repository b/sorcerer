# Sorcerer

An autonomous development system for **building or refactoring large, multi-component, multi-repository systems**.

## How you use it

```
/sorcerer <description of the system to build or refactor>
```

You type that — multi-line markdown is fine — and walk away. Sorcerer's coordinator runs detached and autonomously:

1. **Architects** the work into sub-epics with explicit boundaries.
2. **Designs** each sub-epic into a Linear epic with concrete issues (one per atomic merge).
3. **Implements** each issue across the relevant repos via per-repo worktrees.
4. **Reviews** every PR set against acceptance criteria and merges when ready.

The coordinator self-exits when there's no pending work and self-restarts the next time you invoke `/sorcerer`. No daemon to remember to start, no manual ticks, no babysitting.

`/sorcerer` is overkill for minor fixes or single-file tweaks — those don't need this machinery.

## Status

Full pipeline alive end-to-end: Tier-1 architect → Tier-2 designer → Tier-3 implement → LLM-gated PR-set review → squash merge → cleanup. Cross-epic dependency gating, live event streaming (`/sorcerer attach`), replayable history (`/sorcerer log`), and selective `PushNotification` on milestone events are in. JSON-everywhere, no Python runtime dependency.

See [`STATUS.md`](STATUS.md) for the slice log and the current open work list.

## Documentation

Read in order:
- [`docs/architecture.md`](docs/architecture.md) — components, stack, data flow, multi-repo model
- [`docs/design-flow.md`](docs/design-flow.md) — three-tier request → design → issues workflow
- [`docs/lifecycle.md`](docs/lifecycle.md) — coordinator tick, wizard phases, PR-set review
- [`docs/setup.md`](docs/setup.md) — external access, two-tier repo allowlist, doctor, multi-subscription provider cycling

## Quick start

1. Install CLI prereqs: `git`, `claude` (2.1.1+), `gh` (2.40+), `jq`, `curl`, `openssl`, `uuidgen`, `shellcheck`. No Python needed.
2. Complete [`docs/setup.md`](docs/setup.md) — GitHub App, Linear MCP, branch protection. Bare clones are auto-created on first use.
3. Install sorcerer (one-time):
   ```
   bash scripts/install-skill.sh
   ```
   This symlinks the `/sorcerer` skill into `~/.claude/skills/`, pre-approves its Bash invocation in `~/.claude/settings.json`, writes `SORCERER_REPO` into `~/.shell_env`, and **auto-installs the `/wizard` skill** from [vlad-ko/claude-wizard](https://github.com/vlad-ko/claude-wizard) (MIT) if it's not already present. Sorcerer's implement/feedback wizards invoke `/wizard`'s TDD methodology.
4. Verify:
   ```
   bash scripts/doctor.sh
   ```
5. In any Claude Code session, from the project you want sorcerer to work on:
   ```
   /sorcerer <your large-system description>
   ```
   A `.sorcerer/` directory is auto-bootstrapped in that project on first run.

## Slash commands

| Command | What it does |
|---|---|
| `/sorcerer <prompt>` | Submit a new request. Auto-attaches to the live event stream. |
| `/sorcerer --force <prompt>` | Submit even if an identical prompt is already in flight (bypasses the dedup guard). |
| `/sorcerer status` | Print pending requests + in-flight architects/wizards summary + raw `sorcerer.json`. |
| `/sorcerer attach` | Re-attach to a running coordinator's event stream. Ctrl-C detaches; coordinator keeps running. |
| `/sorcerer log` | Print the full formatted event history for this project. |
| `/sorcerer stop` | Stop the coordinator gracefully (SIGTERM, then SIGKILL if it lingers). |

## Lifecycle architecture

Each coordinator iteration is split across three phases by `scripts/coordinator-loop.sh`:

```
┌─ pre-tick.sh ─────┐  ┌─ LLM tick ──────────────────┐  ┌─ post-tick.sh ────┐
│ Step 1 reconcile  │  │ Step 4  spawn architects    │  │ Step 13 cleanup    │
│ Step 2 token      │→ │ Step 5  detect completions  │→ │ Step 14 archive    │
│ Step 3 drain reqs │  │ Step 6  spawn designers     │  │                    │
└───────────────────┘  │ Step 7  orphan-issue sweep  │  └────────────────────┘
                       │ Step 8  pick implements     │
                       │ Step 9  worktree prep       │
                       │ Step 10 spawn implements    │
                       │ Step 11 heartbeat / throttle│
                       │ Step 11d orphan-PR adoption │
                       │ Step 12 PR-set review (lazy)│
                       │ Step 15 persist state       │
                       └─────────────────────────────┘
```

Pre-tick and post-tick are deterministic bash that doesn't need an LLM. The LLM tick (`claude -p` with the merged tick prompt) handles the spawn / completion / review judgment that does. Step 12's body lives in `prompts/tick-step-12-pr-review.md` and is loaded on demand only when an `awaiting-review` wizard exists — most ticks never read it.

## Resilience features

Sorcerer recovers from the failure modes that show up in real long runs:

- **PR-set recovery**: when a wizard dies after pushing PRs but before writing its completion marker, post-tick discovers the PR set on GitHub and routes the wizard to `awaiting-review` instead of marking it failed.
- **Orphan-PR adoption**: open bot-authored PRs whose `active_wizards` entry was pruned get re-adopted as `awaiting-review` entries with a synthesized state dir.
- **Failed-wizard WIP preservation**: before transitioning a failed implement/feedback/rebase wizard to `failed`, the worktree contents are committed and force-pushed to a `wip/<wizard-id>` branch so the work isn't lost.
- **Linear-Done drift recovery**: post-tick's reconciliation sweep walks recently-merged wizards, queries Linear for their issue's current state, and re-pushes Done if the integration's automatic transition didn't fire.
- **Standalone-issue sweeper** (step 7): every 30 ticks, scans Linear for Urgent/High issues that no architect plan or designer manifest covers; auto-files a fresh `/sorcerer` request for stable orphans.
- **Stale-heartbeat respawn**: implement wizards whose `heartbeat` file goes stale beyond a threshold are SIGTERM'd and respawned (or escalated after the second strike).
- **Wall-clock kill switch**: per-mode `max_wizard_age_seconds` ceilings catch wizards stuck in non-terminating shell loops.
- **Rebase wizards**: PRs that merge as `BEHIND`/`DIRTY` are re-routed to a `rebase` wizard that rebases onto the current default branch and resolves conflicts.
- **Linear-aware idle**: even with `sorcerer.json` empty, the coordinator stays alive while Linear has unclaimed non-terminal issues — keeps the loop alive long enough for step 7 to discover and dispatch them.

## Multi-subscription provider cycling

Sorcerer supports cycling across multiple Anthropic auth slots (Max subscription OAuth tokens, API keys, Bedrock, Vertex). Configure in `<project>/.sorcerer/config.json`:

```json
"providers": [
  { "name": "max-primary",   "env": { "CLAUDE_CODE_OAUTH_TOKEN": "${CLAUDE_CODE_OAUTH_TOKEN_A}" } },
  { "name": "max-secondary", "env": { "CLAUDE_CODE_OAUTH_TOKEN": "${CLAUDE_CODE_OAUTH_TOKEN_B}" } }
]
```

When a provider hits HTTP 429, the tick parses the reset window from the error message (`scripts/extract-reset-iso.sh`), marks `providers_state[<name>].throttled_until`, and the next spawn picks the next available slot via `scripts/apply-provider-env.sh`. When every slot is throttled, the coordinator pauses (`paused_until`) and resumes when the earliest slot reopens. See [`docs/setup.md` § Provider cycling](docs/setup.md#provider-cycling-multiple-anthropic-subscriptions--api-keys) for the full setup.

## Repository layout

This repo (the sorcerer tool):

```
.claude/skills/sorcerer/   # the /sorcerer slash command
prompts/                   # architect / wizard / coordinator-tick prompts
  sorcerer-tick.md           # main coordinator-tick prompt (steps 4-12, 15)
  tick-step-12-pr-review.md  # lazy-loaded step 12 body (only Read when needed)
  architect.md               # Tier-1 architect mandate
  wizard-design.md           # Tier-2 designer mandate
  wizard-architect-review.md # architect plan reviewer
  wizard-design-review.md    # designer manifest reviewer
  wizard-implement.md        # Tier-3 implement wizard mandate
  wizard-feedback.md         # refer-back addressing
  wizard-rebase.md           # merge-conflict / branch-behind resolution
  second-opinion-review.md   # blind-review prompt for the merge gate
scripts/                   # all tooling
  coordinator-loop.sh        # outer loop (pre-tick → LLM → post-tick → sleep)
  pre-tick.sh                # state reconciliation, token refresh, request drain
  post-tick.sh               # merged-PR cleanup, archival
  spawn-wizard.sh            # one-shot wizard launcher (architect/design/implement/...)
  apply-provider-env.sh      # provider rotation (sets OAuth/API env per spawn)
  refresh-token.sh           # GitHub App installation-token mint
  doctor.sh                  # comprehensive health check
  ensure-bare-clones.sh      # auto-create + refresh bare clones for explorable_repos
  has-linear-work.sh         # Linear-aware idle check (Haiku-backed)
  linear-get-state.sh        # read Linear issue status (Haiku-backed)
  linear-set-state.sh        # write Linear issue status (Haiku-backed)
  discover-pr-set.sh         # GitHub PR-set discovery (recovery)
  discover-orphan-prs.sh     # find bot-authored PRs no wizard claims (step 11d)
  adopt-orphan-pr.sh         # synthesize a wizard entry for an orphan PR
  preserve-wizard-wip.sh     # force-push uncommitted worktree to wip/<wizard-id>
  extract-reset-iso.sh       # parse 429 reset timestamps
  append-escalation.sh       # one-line escalations.log writer
  second-opinion-review.sh   # adversarial blind reviewer for the merge path
  start-coordinator.sh       # idempotent launch (handles stale pid + orphans)
  stop-coordinator.sh        # graceful stop
  restart-coordinator.sh     # stop + start
  sorcerer-submit.sh         # /sorcerer skill entry point
  sorcerer-attach.sh         # /sorcerer attach implementation
  format-event.sh            # /sorcerer log human formatter
  install-skill.sh           # one-time installer
  lib-coordinator-procs.sh   # shared process-management helpers
  lint.sh                    # repo-wide shellcheck
  lint-prompts.sh            # prompt-prose linter (hedged-mandatory phrasing, etc.)
  test-linear.sh             # diagnostic: probe Linear MCP visibility from claude -p
config.json.example        # template for per-project config.json
```

Per-project state lives under `<your-project>/.sorcerer/`:

```
.sorcerer/
  config.json                      # per-project config (auto-bootstrapped on first /sorcerer call)
  sorcerer.json                    # coordinator's live state (active_architects + active_wizards + providers_state)
  events.log                       # append-only JSONL progress log
  escalations.log                  # append-only JSONL escalations
  coordinator.pid                  # registered coordinator PID
  coordinator.log                  # append-only stdout from the loop (tick output, pre/post-tick logs, doctor output)
  last-tick.log                    # the most recent LLM tick's raw stdout (overwritten each tick)
  last-doctor.log                  # the most recent doctor.sh output
  .token-env                       # GitHub App installation token cache (sourced by spawn scripts and post-tick)
  .linear-work-cache               # 5-minute cache of "Linear has unclaimed work?" answer
  requests/                        # queued request markdown files awaiting drain
  architects/<arch-id>/            # per-architect state
    request.md
    plan.json
    design.md
    context.json
    provider                       # the provider name this architect ran on
    heartbeat                      # touched while running; absent when exited
    logs/                          # spawn.txt, spawn-N.txt, etc.
  wizards/<wizard-id>/             # per-wizard state (designers + reviewers + adopted orphans)
    manifest.json                  # designer's output (epic + issues)
    review.json                    # reviewer's verdict
    issues/<SOR-N>/                # per-issue dir (implement/feedback/rebase wizards)
      meta.json                    # issue + repos + branch + worktrees
      pr_urls.json                 # {repo: pr_url} once PRs are open
      heartbeat
      logs/                        # spawn.txt, feedback-N.txt, rebase-N.txt
      trees/<owner>-<repo>/        # per-repo git worktree
  repos/<owner>-<repo>.git/        # bare clones, one per explorable repo
```

## Common commands

```bash
# What's in flight right now?
/sorcerer status

# Watch live (Ctrl-C detaches; coordinator keeps running)
/sorcerer attach

# Replay the full event history with human-readable formatting
/sorcerer log

# Stop the coordinator (graceful)
/sorcerer stop

# Re-run the health checks any time
bash $SORCERER_REPO/scripts/doctor.sh
```

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `/sorcerer status` shows no progress for hours | Linear MCP needs auth in the spawned `claude -p` context | Run `/mcp` in an interactive session, complete OAuth. If `~/.claude/.credentials.json` already has a token but `~/.claude/mcp-needs-auth-cache.json` says needs-auth, clear that cache file and re-run. |
| Wizards stuck at `status=merging` | `gh pr view` returning empty (no GitHub App token) | Check `.sorcerer/.token-env` is non-empty; pre-tick should refresh it. If pre-tick logs `token refresh failed`, ensure `.sorcerer/config.json:repos[0]` has an owner reachable by your App installation. |
| Wizards stuck at `status=blocked` after a transient failure | Likely a one-time partial-merge or `merge-blocked` decision; PRs may now be MERGED | Inspect each PR's actual state via `gh pr view`. If all merged, manually flip the wizard back to `status=merging` via a `jq` mutation on `sorcerer.json`; the next post-tick will process it correctly. |
| `coordinator-loop received SIGTERM` immediately after `/sorcerer stop` | Expected | The loop traps SIGTERM and exits cleanly. |
| All providers throttled | One Anthropic account hit rate limits across all configured slots | The coordinator sets `paused_until` to the earliest reset and sleeps. Add more slots to `config.json:providers`, or wait. |
| Linear status drifts (PR merged, Linear still In Progress) | Linear-GitHub integration didn't fire AND post-tick's reconciliation sweep hasn't found the wizard | Run `/sorcerer status` to confirm the wizard is at `status=merged`. The reconciliation sweep retries on every post-tick — if Linear MCP is reachable, it self-heals within minutes. If wedged, push manually via `mcp__plugin_linear_linear__save_issue` from your interactive session. |
| Doctor reports `Linear MCP NOT visible to claude -p` | Three possible causes — the doctor's diagnosis line tells you which | (1) No token in `~/.claude/.credentials.json`: re-do `/mcp`. (2) Token present, cache stale: `echo '{}' > ~/.claude/mcp-needs-auth-cache.json`. (3) Token present, cache clean, probe still fails: token expired or revoked, re-do `/mcp` to refresh. |

## Telemetry & observability

- `events.log` — JSONL, append-only. Every milestone (`architect-spawned`, `designer-completed`, `implement-spawned`, `review-merge`, `issue-merged`, `coordinator-paused`, `pr-orphan-adopted`, `wizard-throttled`, etc.) lands here. Format with `scripts/format-event.sh` or via `/sorcerer log`.
- `escalations.log` — JSONL, append-only. One record per failure that needs operator attention (`architect-no-output`, `designer-self-reported-failure`, `persistent-throttle`, `partial-merge`, `merge-blocked`, `linear-done-push-failed`, `wizard-max-age-exceeded`, etc.).
- Push notifications — selective milestones fire mobile-targeted `PushNotification` calls (architect-completed, issue-merged, escalation-logged, coordinator-paused). Configurable per-environment.

## Contributing

Issues + PRs welcome at [github.com/b/sorcerer](https://github.com/b/sorcerer). The repo is small enough to read end-to-end in one sitting; the hot paths are `prompts/sorcerer-tick.md` (the LLM tick), `scripts/coordinator-loop.sh` (the outer loop), and `scripts/{pre,post}-tick.sh` (the deterministic edges).
