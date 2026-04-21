# Design Flow

How a user feature request becomes a fully-specified design, then concrete issues worked by wizards. Three tiers, scaling to complexity.

## Scaling decision

At request intake, the coordinator picks the tier:

- **Small / medium** — skip Tier 1. Invoke Tier 2 directly: one designer wizard, one epic. Default for most requests.
- **Large / complex** — Tier 1 first (architect), then N Tier-2 designers in parallel (one per sub-epic).

Heuristic (from `config.json:architect.auto_threshold`):
- Request likely touches ≥ `min_repos` distinct repos *or*
- Estimated to produce ≥ `min_issues_estimate` issues *or*
- The user explicitly sets `scale: large` in the request, or invokes `--architect`.

Users override by adding `scale: small | medium | large` to the top of the request file.

## Tier 1 — Architect

**Goal**: produce a durable design doc and a sub-epic plan. Does **not** create Linear issues.

**Inputs**: the feature request, `explorable_repos`, `repos`.

**Outputs**:
- `.sorcerer/architects/<id>/design.md` — goals, component map (which repos host which parts of the change), risks and unknowns, staging order, cross-sub-epic contracts and invariants.
- `.sorcerer/architects/<id>/plan.json` — the sub-epic plan:
  ```json
  {
    "design_doc": "design.md",
    "sub_epics": [
      {
        "name": "<short title>",
        "mandate": "<scoped mandate — what this sub-epic owns, and explicitly what it does NOT own; \\n for newlines>",
        "repos": ["<subset of architect's repos>"],
        "explorable_repos": ["<subset of architect's explorable_repos>"],
        "depends_on": ["<other sub-epic names>"]
      }
    ],
    "cross_sub_epic_contracts": "<interfaces and invariants sub-epics must honor between each other>"
  }
  ```

**Rules**:
- The architect doesn't implement and doesn't write Linear issues. Tier 2 does both.
- Sub-epic boundaries should maximize parallelism — fewer inter-epic dependencies, better.
- Every sub-epic's `repos`/`explorable_repos` must be subsets of the architect's.
- If the request genuinely is one coherent slice (even multi-repo), emit exactly one sub-epic and note that Tier 1 was light.

**When Tier 1 gets it wrong**: a Tier-2 designer whose mandate turns out inconsistent or impossible escalates under rule "architect plan invalid mid-flight". Sorcerer does **not** autonomously re-run Tier 1 — only the user can authorize re-planning.

## Tier 2 — Sub-epic designer

**Goal**: turn one sub-epic mandate into a Linear epic + child issues.

Exactly the existing `mode: design` flow in [`SORCERER.md`](../../../.claude/skills/wizard/SORCERER.md), with the sub-epic's `scope` and `architect_plan_file` passed through the context. The designer wizard honors the mandate. If it believes the mandate is wrong, it escalates — it never silently reinterprets.

**Outputs**: one Linear project (epic) + child issues, each with:
- Acceptance criteria
- `repos: [...]` — every repo the issue touches (must be a subset of the sub-epic's `repos`)
- Optional `merge_order: [...]` — declares serial merge order within the issue's PR set (e.g. protos before service)
- Optional `depends_on: [...]` — may reference issues from sibling sub-epics **only** if the architect plan declared the cross-epic contract

**Parallelism**: Tier-2 designers run concurrently (up to `limits.max_concurrent_wizards`), unless the architect plan orders them.

## Tier 3 — Implement

Once issues exist, the coordinator schedules `implement` sessions per the rules in [`lifecycle.md`](lifecycle.md). Cross-sub-epic `depends_on` is respected — an issue isn't scheduled until every prerequisite is `Done`.

Sub-epic wizards are fully independent processes and can run in parallel if the architect plan declares no dependencies.

## Artifacts and where they live

| Artifact | Produced by | Location |
|---|---|---|
| Feature request | user | `.sorcerer/requests/*.md` (moved to architect or wizard dir on intake) |
| Design doc | architect (Tier 1) | `.sorcerer/architects/<id>/design.md` |
| Sub-epic plan | architect (Tier 1) | `.sorcerer/architects/<id>/plan.json` |
| Epic + issues | designer (Tier 2) | Linear |
| Wizard manifest | designer (Tier 2) | `.sorcerer/wizards/<id>/manifest.json` |
| Per-issue meta | coordinator | `.sorcerer/wizards/<id>/issues/<id>/meta.json` |
| Review history | coordinator | `.sorcerer/events.log` + PR comments on GitHub |

## Anti-patterns

- **Tier 1 creating Linear issues.** Don't. Issues are Tier-2 output.
- **Tier 2 questioning the architect's component breakdown.** If a sub-epic designer disagrees with its mandate, escalate. Reinterpretation silently breaks cross-sub-epic contracts.
- **Cross-sub-epic `depends_on` not in the architect plan.** Tier-2 designers may only declare cross-epic dependencies the architect already acknowledged. An emergent cross-epic dep mid-design → escalate, not declare.
- **Serial merges across sub-epics without architect approval.** If sub-epic A's merges must precede sub-epic B's, that's an architect-plan concern. Tier 2 doesn't invent it.
- **Autonomous Tier-1 re-runs.** Don't. Re-planning destabilizes in-flight wizards. User-gated always.

## User override

Users can always:
- Set `scale:` in the request to force or skip Tier 1.
- Edit `.sorcerer/architects/<id>/plan.json` before Tier-2 spawns (coordinator re-reads on the next tick after the architect exits).
- Stop the coordinator via `/sorcerer stop`.
- Reject an architect plan by deleting `plan.json` and writing a replacement, or by starting over with an edited request.
