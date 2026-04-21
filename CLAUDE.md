# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Sorcerer is an autonomous development system, built from the ground up for work that spans multiple repositories. A top-level **sorcerer** coordinator dispatches **wizards** — autonomous agents following the `/wizard` skill methodology — that design and implement features end-to-end, from Linear epic(s) to merged PR set(s). Large or complex requests are first planned by a Tier-1 **architect** session that produces a durable design doc and breaks work into sub-epics, each handled by its own wizard.

This repository currently contains design documentation only. No implementation exists yet.

## User-facing entry point

The user interacts with sorcerer **only** through the `/sorcerer` slash command (defined at `.claude/skills/sorcerer/SKILL.md`). The user types `/sorcerer <description of the system to build or refactor>` and walks away — sorcerer's coordinator handles the rest detached. Manual tick invocation, manual file drops into `state/requests/`, and manual coordinator starts are all regressions and must not be reintroduced.

The `/sorcerer` skill itself does only two things: writes the prompt to a timestamped file under `state/requests/`, and ensures the coordinator is running by calling `scripts/start-coordinator.sh` (idempotent — spawns a detached `scripts/coordinator-loop.sh` if no live coordinator pid).

## Orientation

Read in order:

1. [`docs/architecture.md`](docs/architecture.md) — components, stack, data flow, multi-repo model
2. [`docs/design-flow.md`](docs/design-flow.md) — three-tier request → design → issues workflow
3. [`docs/lifecycle.md`](docs/lifecycle.md) — coordinator tick, wizard phases, PR-set review
4. [`docs/setup.md`](docs/setup.md) — external access, two-tier repo allowlist, `.env`

## Design invariants

If a proposed change would violate one of these, stop and flag it to the user.

- **Sorcerer never pushes to a protected branch directly.** Everything lands via a PR and the repo's own merge gate.
- **Multi-repo is first-class, not a bolt-on.** Every issue declares `repos: [...]`. PR review is per-issue (one decision across the whole set of PRs), never per-PR.
- **One wizard owns one epic; one issue at a time within that wizard's scope.** A single issue may hold worktrees in many repos simultaneously, but no two wizards share a worktree.
- **Linear is the source of truth for issue state. GitHub is the source of truth for code.** Sorcerer's local state is a recoverable cache.
- **Architect decides boundaries. Designer decides issues. Wizard decides implementation.** Tier-2 designers honor the architect's mandate and escalate if they disagree; they never silently reinterpret.
- **User escalation is a short, specific list.** See [`docs/lifecycle.md`](docs/lifecycle.md) § "User escalation". Anything not on that list, sorcerer decides.
- **Wizards follow the `/wizard` skill.** Phased methodology lives in that skill's `SKILL.md`; sorcerer-mode specifics (context schema, multi-repo patterns, escalation rules) live in its `SORCERER.md`.

## Stack

- Claude Code `/loop` session for the coordinator.
- `claude -p` subprocesses for architect and wizard sessions.
- `gh` CLI for GitHub; reads `$GITHUB_TOKEN`, a GitHub App installation token minted by `scripts/refresh-token.sh` (standalone — no cross-repo dependencies).
- Linear MCP (`mcp__plugin_linear_linear__*`) for Linear.
- `git` + `git worktree` for per-issue isolation — one worktree per (issue × affected repo), off bare clones under `<project>/.sorcerer/repos/`.
- Plain JSON / JSONL files under `<project>/.sorcerer/` for coordinator state (`sorcerer.json`, `meta.json`, `context.json`, `plan.json`, `manifest.json`, `events.log`, `escalations.log`). `config.json` is the only human-authored file.
- `jq` + `uuidgen` for all serialization and id generation. No Python anywhere.

No Python, no SQLite, no daemon, no GitHub MCP. Rationale in `docs/architecture.md` § "Stack".

Build, lint, and test commands will be added here once implementation begins.
