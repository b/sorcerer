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

The coordinator self-exits when there's no pending work, and self-restarts the next time you invoke `/sorcerer`. No daemon to remember to start, no manual ticks, no babysitting.

`/sorcerer` is overkill for minor fixes or single-file tweaks — those don't need this machinery.

## Status

Full pipeline alive end-to-end: Tier-1 architect → Tier-2 designer → Tier-3 implement → LLM-gated PR-set review → squash merge → cleanup. Cross-epic dependency gating, live event streaming (`/sorcerer attach`), replayable history (`/sorcerer log`), and selective `PushNotification` on milestone events are in. JSON-everywhere, no Python runtime dependency.

See [`STATUS.md`](STATUS.md) for the slice log and the current open work list.

## Documentation

Read in order:
- [`docs/architecture.md`](docs/architecture.md) — components, stack, data flow, multi-repo model
- [`docs/design-flow.md`](docs/design-flow.md) — three-tier request → design → issues workflow
- [`docs/lifecycle.md`](docs/lifecycle.md) — coordinator tick, wizard phases, PR-set review
- [`docs/setup.md`](docs/setup.md) — external access, two-tier repo allowlist, doctor

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
6. Monitor live (streams new events):
   ```
   /sorcerer attach
   ```
   Or scroll the full history:
   ```
   /sorcerer log
   ```
7. Stop everything (graceful):
   ```
   /sorcerer stop
   ```

## Repository layout

```
.claude/skills/sorcerer/   # the /sorcerer slash command
prompts/                   # architect / wizard / coordinator-tick prompts
scripts/                   # coordinator + spawn + doctor + token refresh
config.json.example        # template for per-project config.json
```

At runtime, everything project-specific lives under `<your-project>/.sorcerer/`:

```
.sorcerer/
  config.json              # per-project config (auto-bootstrapped on first /sorcerer call)
  sorcerer.json            # coordinator's live state (active_architects + active_wizards)
  events.log               # append-only JSONL progress log
  escalations.log          # append-only JSONL escalations
  coordinator.{pid,log}    # detached coordinator process state
  requests/                # queued request markdown files
  architects/<id>/         # per-architect state dirs (plan.json, logs/, etc.)
  wizards/<id>/            # per-wizard state dirs (manifest.json, issues/, logs/, etc.)
  repos/<owner>-<repo>.git # bare clones, one per explorable repo
```
