# Sorcerer

An autonomous development system. Hand it a feature request; it returns merged code.

**Status:** design phase. This repository currently contains architecture documentation. Implementation has not started.

## How it works

Sorcerer is a coordinator. When you submit a feature request, it spawns a **wizard** — a dedicated agent that:

1. **Designs** the work, producing an epic with associated issues in Linear.
2. **Executes** each issue in an isolated worktree: branches, implements, tests, opens a pull request.
3. **Iterates** on review feedback until the PR is mergeable.

Sorcerer monitors every active wizard, reviews their PRs, merges or refers back, and only interrupts the user when something genuinely requires a human.

## Documentation

Read in this order:

- [`docs/architecture.md`](docs/architecture.md) — components, data flow, state model, failure handling
- [`docs/lifecycle.md`](docs/lifecycle.md) — what sorcerer and wizards do, step by step
- [`docs/setup.md`](docs/setup.md) — GitHub and Linear access requirements, with exact setup steps
- [`CLAUDE.md`](CLAUDE.md) — guidance for Claude Code sessions working on this repo

## Quick start

Not yet available. See [`docs/setup.md`](docs/setup.md) for the access you can start preparing now.
