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

Bootstrap complete; pipeline alive end-to-end through Tier-1 (architect). Tier-2 designer wizards, Tier-3 implement wizards, and PR-set review/merge are in progress.

## Documentation

Read in order:
- [`docs/architecture.md`](docs/architecture.md) — components, stack, data flow, multi-repo model
- [`docs/design-flow.md`](docs/design-flow.md) — three-tier request → design → issues workflow
- [`docs/lifecycle.md`](docs/lifecycle.md) — coordinator tick, wizard phases, PR-set review
- [`docs/setup.md`](docs/setup.md) — external access, two-tier repo allowlist, doctor

## Quick start

1. Complete [`docs/setup.md`](docs/setup.md) — GitHub App, Linear MCP, bare clones, branch protection.
2. From the sorcerer repo, in Claude Code:
   ```
   /sorcerer <your large-system description>
   ```
3. Monitor (any terminal, any time):
   ```
   tail -f state/coordinator.log state/events.log
   ```
4. Stop everything (graceful):
   ```
   bash scripts/stop-coordinator.sh
   ```

## Repository layout

```
.claude/skills/sorcerer/   # the /sorcerer slash command
prompts/                   # architect / wizard / coordinator-tick prompts
scripts/                   # coordinator + spawn + doctor + token refresh
state/                     # runtime state — gitignored
repos/                     # bare clones of allowlisted repos — gitignored
config.yaml                # per-user config (gitignored; copy from config.yaml.example)
```
