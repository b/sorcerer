# Step 6 — Spawn designers

For each `active_architects` entry with `status: awaiting-tier-2`:

**Architect-dependency gate.** If the entry has a non-empty `depends_on_architects: ["<arch-id>", ...]` array, check each listed architect id against `active_architects`. The dependency is satisfied when the listed architect's status is **`completed`** or **`archived`** (terminal-success states); a dependency in any other state (running, awaiting-tier-2, failed, etc.) blocks. If ANY listed dependency is not yet satisfied, emit `tick: step-6 — architect <id-short> waiting on <dep-id-short> (status=<dep-status>); skipping designer spawn` and skip this architect (do not run sub-step 0 either; the epic stays at whatever state step 4a wrote, and the designer fan-out waits). Sorcerer never sets or clears `depends_on_architects`; it's strictly an operator override (edit sorcerer.json to defer one architect's fan-out until others' chains complete). Listed architects that don't exist in `active_architects` are treated as **satisfied** (so historical/archived ids that fell out of state don't permanently block; the operator can audit via events.log if needed).

0. **Update or create Linear epic parent.** Two paths depending on whether step 4a already filed the epic at submit time:

   **Path A (typical, post-SOR-537): epic was filed at submit time.** If the architect entry's `epic_linear_id` is non-null AND the architect has just transitioned to `awaiting-tier-2` (i.e. this is the first tick on which the plan is observable), update the existing epic with the plan summary:
   - Read `.sorcerer/architects/<arch-id>/design.md` (first ~500 chars of the **Goal** section).
   - Read `.sorcerer/architects/<arch-id>/plan.json` and extract the bulleted list of `sub_epics[].name`.
   - Compose the updated description: original request body (preserved from step 4a's create) + a new `## Plan` section with the design summary + sub-epic bullets + footer line `<!-- sorcerer architect <arch-id-short> -->`.
   - Call `mcp__plugin_linear_linear__save_issue` with:
     - `id`: `<epic_linear_id>`
     - `description`: the updated body
     - `state`: `"In Progress"`
     - **Do NOT pass `parentId`** — leave the epic top-level.
   - Append event:
     ```json
     {"ts":"...","event":"epic-issue-updated","architect_id":"<arch-id>","epic_linear_id":"<id>","stage":"plan-ready"}
     ```
   To avoid re-applying this update on every subsequent tick, gate it: skip when an `epic-issue-updated` event with `stage: plan-ready` already exists in events.log for this `architect_id`. (The CREATE-time `epic-issue-filed` event from step 4a is distinct.)

   **Path B (backwards-compat, legacy): epic was never filed.** If the architect entry's `epic_linear_id` is null (legacy entry from before SOR-537 landed, or step 4a's create failed transiently):
   - Read `.sorcerer/architects/<arch-id>/request.md` for the title seed; use the first non-empty line, stripped of leading `#` chars and limited to ~80 chars.
   - Read `.sorcerer/architects/<arch-id>/design.md` for the description (first ~500 chars of the **Goal** section, plus a bulleted list of `plan.json:sub_epics[].name`). If `design.md` is missing, fall back to a 1-line summary derived from request.md.
   - Read `<project-root>/.sorcerer/config.json:linear.project_uuid` for the target project.
   - Call `mcp__plugin_linear_linear__save_issue` once with:
     - `title`: `Epic: <derived title>`
     - `description`: the markdown body composed above, ending with a footer line `<!-- sorcerer architect <arch-id-short> -->`.
     - `project`: `<config.json:linear.project_uuid>`
     - `state`: `"In Progress"`
     - `labels`: omit.
     - **Do NOT pass `parentId`** — epics are top-level.
   - Capture the response's `id`.
   - Update the architect entry: `epic_linear_id: "<id>"`. Atomic write of `sorcerer.json`.
   - Append event:
     ```json
     {"ts":"...","event":"epic-issue-filed","architect_id":"<arch-id>","epic_linear_id":"<id>","stage":"plan-ready-fallback"}
     ```

   On any `save_issue` failure (either path): append an `epic-file-failed` escalation with `rule: epic-file-failed`, leave the entry as-is, and proceed with designer spawn anyway. Designers tolerate `epic_linear_id: null`; the epic can be created/updated on a later tick.

1. Read `.sorcerer/architects/<arch-id>/plan.json`. Parse `sub_epics` (list of objects with `name`, `mandate`, `repos`, `explorable_repos`, optional `depends_on`).

2. Check concurrency: read `config.json:limits.max_concurrent_wizards` (default 3). Count entries with `status: running` across `active_architects + active_wizards`.

3. **Cross-epic dependency helper.** Define `sub_epic_fully_merged(arch_id, sub_epic_name)` for use below. A sub-epic is "fully merged" when its designer has completed AND every issue in its manifest has a corresponding implement wizard whose status is `merged` or `archived`:

   - Find the `active_wizards` entry with `mode: design`, `architect_id == arch_id`, and `sub_epic_name == <name>`.
     - If missing, or `manifest_file` is null, or status is not one of `completed | archived`: return **false** (the dep hasn't even finished designing).
   - Read that entry's `manifest_file`. For each issue in `manifest.issues`:
     - Find the `active_wizards` entry with `mode: implement` and `issue_linear_id == issue.linear_id` (fall back to `issue_key` match if needed).
     - If missing, or status is not one of `merged | archived`: return **false**.
   - If every issue passed: return **true**.

4. For each `sub_epic` at index `i` in the list:
   - **Skip if already spawned.** If any `active_wizards` entry matches `architect_id == <arch-id>` and `sub_epic_name == <name>`, move on (re-entry safety).
   - **Cross-epic dep gate (strict).** If `sub_epic.depends_on` is non-empty, resolve each `dep_name` against the plan's `sub_epics` list (match by `name`). For each resolved dep:
     - If the dep is not found in the plan at all: append to `.sorcerer/escalations.log` with `rule: sub-epic-dep-not-in-plan`, `wizard_id: null`, a short explanation, and skip this sub-epic for this tick (don't spawn; next tick re-evaluates but an operator should inspect).
     - Otherwise call `sub_epic_fully_merged(<arch-id>, <dep_name>)`. If it returns **false**: emit `tick: deferring designer spawn for sub-epic "<name>" — dep "<dep_name>" not yet fully merged` and skip this sub-epic for this tick.
   - If all deps are satisfied (or there were none), proceed:
     - **Concurrency check.** If running-count is at the limit: emit `tick: concurrency-limit reached, deferring designer spawn for sub-epic "<name>"` and stop evaluating further sub-epics for this architect (the next tick will pick up).
     - Otherwise:
       - Generate UUID: `uuidgen`.
       - `mkdir -p .sorcerer/wizards/<wizard-id>/logs`.
       - Spawn the designer. Pass `--epic-linear-id` when the architect entry's `epic_linear_id` is non-null so the designer's `save_issue` calls set `parentId` on each sub-task. If null (step-0 above failed transiently), omit the flag — the designer falls back to no `parentId` and the epic-file step will retry next tick.
         ```bash
         nohup bash "$SORCERER_REPO/scripts/spawn-wizard.sh" design \
           --wizard-id <wizard-id> \
           --architect-plan-file .sorcerer/architects/<arch-id>/plan.json \
           --sub-epic-index <i> \
           ${epic_linear_id:+--epic-linear-id "$epic_linear_id"} \
           > .sorcerer/wizards/<wizard-id>/logs/spawn.txt 2>&1 &
         echo $!
         ```
       - Capture PID.
       - Append to `active_wizards`:
         ```json
         {
           "id": "<wizard-id>",
           "mode": "design",
           "status": "running",
           "started_at": "<ISO-8601 now>",
           "architect_id": "<arch-id>",
           "sub_epic_index": <i>,
           "sub_epic_name": "<name from sub_epic>",
           "epic_linear_id": "<copied from architect entry, or null>",
           "manifest_file": null,
           "pid": <pid>,
           "respawn_count": 0
         }
         ```
       - Append event:
         ```json
         {"ts":"...","event":"designer-spawned","id":"<wizard-id>","architect_id":"<arch-id>","sub_epic":"<name>","pid":12345}
         ```
       - Increment running-count (for concurrency check on the next sub-epic in this loop).

5. Once ALL sub-epics for an architect have been evaluated, transition the architect's `status` from `awaiting-tier-2` to `completed` ONLY if every sub-epic **named in `plan.json`** has a matching `active_wizards` designer entry in status `completed` or `archived`. Specifically: iterate `plan.json:sub_epics[].name`, and for each name verify there exists an entry with `mode == "design"`, `architect_id == <this-architect>`, `sub_epic_name == <name>`, AND status in `{completed, archived}`. If ANY sub-epic name lacks such an entry — including sub-epics that haven't had a designer spawned yet because their cross-epic deps were still pending on the previous tick — leave the architect at `awaiting-tier-2`. This keeps the architect in scope of step 6 so a newly-dep-satisfied sub-epic gets its designer spawned on a future tick. The naive rule "every existing designer is completed" is NOT sufficient; it silently succeeds when some sub-epics haven't spawned yet. Leaving the architect at `awaiting-tier-2` also means `has_in_flight_work` stays true while downstream work is still pending.
