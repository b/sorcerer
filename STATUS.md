# Status

Sorcerer is an autonomous development system for building or refactoring large, multi-repository systems. A user invokes it by typing `/sorcerer <description of the system to build or refactor>` in Claude Code and walking away; the coordinator (see [`docs/architecture.md`](docs/architecture.md)) runs detached, drives work through Tier-1 architect → Tier-2 designer → Tier-3 implement → PR-set review, and self-exits when there's no pending work.

## Pipeline (all alive)

- **Tier-1 architect** — decomposes a request into sub-epics with explicit boundaries, plus a blind-reviewer wizard that approves or rejects the plan.
- **Tier-2 designer** — turns each sub-epic into a Linear epic with concrete issues, plus a blind-reviewer wizard for the manifest.
- **Tier-3 implement** — per-issue wizard with worktree, `/wizard` TDD phases, multi-repo branch pushes, one PR per affected repo.
- **Refer-back / feedback / rebase wizards** — addressing review concerns and rebasing BEHIND/DIRTY PRs, both capped by `max_refer_back_cycles` and `conflict_cycle`.
- **Step 12 PR-set review and merge** — five-stage LLM gate (gather → walkthrough → cross-doc → AC mapping → executable AC verification → deferred-work pre-check → second-opinion blind review → merge).
- **Step 13 cleanup + Linear-Done push** — handled deterministically by `scripts/post-tick.sh`, with reconciliation sweep for stuck wizards.
- **Step 14 archive after 7d** — also in `post-tick.sh`.

## Coordinator-loop architecture

```
pre-tick.sh   → state reconcile, token refresh, request drain   (steps 1–3)
LLM tick      → spawn / completion-detect / review / persist     (steps 4–12, 15)
post-tick.sh  → cleanup merged + Linear push, 7d archive         (steps 13–14)
```

The LLM tick reads a 88 KB tick prompt (down from 137 KB after lazy-loading step 12 and extracting bash helpers to scripts).

## Resilience features

- Multi-subscription provider cycling with 429-aware throttle parsing
- Linear-aware idle (coordinator stays alive while Linear has unclaimed backlog)
- Orphan-PR adoption (open bot-authored PRs no wizard claims get re-claimed)
- PR-set recovery (wizards that crash post-push get routed to `awaiting-review` if PRs exist)
- Failed-wizard WIP preservation (commit + push to `wip/<id>` before cleanup)
- Linear-Done drift recovery (reconciliation sweep on merged wizards)
- Standalone-issue sweeper (auto-files requests for Urgent/High orphans every 30 ticks)
- Wall-clock kill switch (per-mode `max_wizard_age_seconds`)
- Stale-heartbeat respawn / second-strike-escalate
- Pre-flight resource gate (disk floor before implement spawn)

## Slice log

The shipped-feature log lives in git: `git log --oneline main` shows every merged PR. Recent highlights:

- Slices 65–68: pre-tick + post-tick deterministic-step extraction; tick prompt -41% size; coordinator stays alive while Linear has work
- Slice 64: orphan-PR adoption (step 11d)
- Slice 63: sandboxed second-opinion reviewer + doctor live-state checks
- Slice 62: round-robin provider rotation
- Slice 61: dep-check via Linear ground truth
- Slice 60: pre-flight resource gate (disk floor)
- Slice 59: stage 6.6 adversarial blind second-opinion reviewer on merge path
- Slice 58: lint-prompts.sh — hedged-mandatory phrasing detector
- Slice 57: referenced-but-excluded SOR enforcement + standalone-issue sweeper
- Slice 56: doctor.sh live-state checks wired into coordinator-loop
- Slice 55: failed-wizard WIP preservation
- Slice 54: stage 6.4.5 executable AC verification (citation-existence + test-asserts-criterion)
- Slice 53: bare-clone freshness — drop stale origin refs, fetch on every ensure
- Slice 52: priority-aware implement-candidate dispatch + Linear-createdAt tiebreak
- Slice 51: safer coordinator restart — survivor sweep + orphan check + restart wrapper
- Slice 50: stage 6.5 mandatory pre-check for deferred-work comments without SOR cross-reference
- Slice 49: mandatory Linear-Done push at step 13 + reconciliation sweep
- Slice 48 and earlier: full architect → designer → implement → review → merge pipeline; see git log for the complete slice ledger.

## Open follow-ups

Maintained as Linear issues in the `SOR` team. The standalone-issue sweeper (step 7) auto-files requests for Urgent/High orphans; lower-priority backlog needs an explicit `/sorcerer` request to drain.
