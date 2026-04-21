# Status

Sorcerer is an autonomous development system for building or refactoring large, multi-repository systems. A user invokes it by typing `/sorcerer <description of the system to build or refactor>` in Claude Code and walking away; the coordinator (see [`docs/architecture.md`](docs/architecture.md)) runs detached, drives work through Tier-1 architect → Tier-2 designer → Tier-3 implement → PR-set review, self-exits when nothing is `pending-architect`, `running`, or `pending-design` and `<project>/.sorcerer/requests/` is empty, and self-restarts the next time `/sorcerer` is invoked.

## Shipped

- Slice 1 — Linear MCP write-path self-test (#1)
- Slice 2 — `spawn-wizard.sh` and noop wizard for spawn-machinery testing (#2)
- Slice 3 — Tier-1 architect mode with dry-run capability (#3)
- Slice 4 — coordinator tick (architect-only path) (#4)
- Slice 5 — `/sorcerer` entry point and self-managing coordinator loop (#5)
- Slice 6 — Tier-2 designer wizard, `/sorcerer` install-from-anywhere, drop budget caps (#6)
- Slice 7 — coordinator-loop counts `awaiting-tier-2` as in-flight (#7)

## What's next

- **Tier-3 implement** — per-issue wizard that creates worktrees, runs `/wizard` phases across the issue's `repos`, pushes branches, and opens one PR per affected repo. See [`docs/lifecycle.md`](docs/lifecycle.md) § "Implement".
- **PR-set review and merge** — coordinator-side review of the full PR set against Linear acceptance criteria, with serial or auto-merge per `merge_order`. See [`docs/lifecycle.md`](docs/lifecycle.md) § "PR set review decision".
- **Feedback / refer-back cycles** — structured refer-back on the primary PR, `feedback` wizard sessions, hard cap at `max_refer_back_cycles`. See [`docs/lifecycle.md`](docs/lifecycle.md) § "Feedback".
- **Epic completion** — summary comment, project close, wizard `done`, 7-day state retention. See [`docs/lifecycle.md`](docs/lifecycle.md) § "Epic completion".
- **Escalation wiring** — the strict user-escalation list routed through `<project>/.sorcerer/escalations.log` (and `PushNotification` when available). See [`docs/lifecycle.md`](docs/lifecycle.md) § "User escalation".
