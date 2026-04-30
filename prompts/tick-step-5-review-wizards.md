# Step 5d/5e — Review-wizard spawn + completion

This file covers two symmetric review-wizard paths invoked from step 5 of the tick:
- **5d** — `architect-review` reviewer for an architect plan
- **5e** — `design-review` reviewer for a designer manifest

Load this file when ANY of the following is true:
- An `active_architects` entry has `status: awaiting-architect-review` (5d spawn) OR `architect-review-running` (5d completion check still needed via the wizard entry)
- An `active_wizards` entry has `mode: design` and `status: awaiting-design-review` (5e spawn) OR `mode: design` and `status: design-review-running`
- An `active_wizards` entry has `mode: architect-review | design-review` and `status: running | throttled` (completion-detection or throttle resume needed)

If none of those hold, neither 5d nor 5e have any work this tick — return without loading this file.

## 5d. Architect-review spawn + completion

**Spawn (when an architect just transitioned to `awaiting-architect-review`):**

For each `active_architects` entry with `status: awaiting-architect-review` AND no `review_wizard_id` set yet:

1. Generate UUID: `uuidgen`. This is the reviewer's wizard id.
2. `mkdir -p .sorcerer/wizards/<reviewer-id>/logs`
3. Spawn the reviewer:
   ```bash
   nohup bash scripts/spawn-wizard.sh architect-review \
     --wizard-id <reviewer-id> \
     --subject-id <arch-id> \
     --subject-state-dir .sorcerer/architects/<arch-id> \
     > .sorcerer/wizards/<reviewer-id>/logs/spawn.txt 2>&1 &
   echo $!
   ```
4. Capture pid. Append to `active_wizards`:
   ```json
   {
     "id": "<reviewer-id>", "mode": "architect-review", "status": "running",
     "started_at": "<ISO-8601 now>",
     "subject_id": "<arch-id>", "subject_kind": "architect",
     "review_decision": null, "review_file": null,
     "pid": <pid>, "respawn_count": 0
   }
   ```
5. Update the architect entry: `status: architect-review-running`, `review_wizard_id: <reviewer-id>`.
6. Append:
   ```json
   {"ts":"...","event":"architect-review-spawned","id":"<reviewer-id>","subject_id":"<arch-id>","pid":12345}
   ```

Concurrency: counts toward `max_concurrent_wizards`. If at the cap, leave the architect at `awaiting-architect-review` and pick up next tick.

**Completion detection (when the reviewer wizard's spawn process exits):**

For each `active_wizards` entry with `mode: architect-review` and `status: running`:

```bash
test -f .sorcerer/wizards/<reviewer-id>/heartbeat && hb_file=present || hb_file=absent
test -f .sorcerer/wizards/<reviewer-id>/review.json && rv=present || rv=absent
if is_pid_alive "<pid>"; then hb="$hb_file"; else hb=absent; fi
last_line=$(tail -1 .sorcerer/wizards/<reviewer-id>/logs/spawn.txt 2>/dev/null)
```

Cases:
- `hb=absent` AND `rv=present` AND `last_line` starts with `ARCHITECT_REVIEW_OK`:
  - Read `.sorcerer/wizards/<reviewer-id>/review.json`. Parse `decision` (`approve` | `reject`) and `edits_made` count.
  - Update reviewer entry: `status: completed`, `review_decision: <decision>`, `review_file: .sorcerer/wizards/<reviewer-id>/review.json`.
  - Update the parent architect entry (look up by `subject_id`): clear `review_wizard_id`.
  - On `decision == "approve"`:
    - Architect entry → `status: awaiting-tier-2`. Step 6 will spawn designers from the (possibly edited) plan.json.
    - Append:
      ```json
      {"ts":"...","event":"architect-review-completed","id":"<reviewer-id>","subject_id":"<arch-id>","decision":"approve","edits":<E>}
      ```
  - On `decision == "reject"`:
    - Architect entry → `status: failed`.
    - Read `concerns_unfixed` from the review.json. Append to `.sorcerer/escalations.log`:
      ```bash
      jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg wizard_id "<arch-id>" \
        --arg rule "architect-review-rejected" \
        --slurpfile review .sorcerer/wizards/<reviewer-id>/review.json \
        '{ts:$ts, wizard_id:$wizard_id, mode:"architect", issue_key:null, pr_urls:null, rule:$rule,
          attempted: ($review[0].summary // ""),
          needs_from_user: ("Review reviewer concerns and decide: edit request, edit plan.json by hand, or rerun architect with revised request. Reviewer concerns: " + ($review[0].concerns_unfixed | tostring)),
          review_file: "<path to review.json>"}' \
        >> .sorcerer/escalations.log
      ```
    - Append `architect-review-completed` event with `decision: "reject"`.
- `hb=absent` AND `last_line` starts with `ARCHITECT_REVIEW_FAILED`:
  - Reviewer reported its own failure. Update reviewer `status: failed`, parent architect `status: failed`. Escalate with `rule: architect-review-self-reported-failure`.
- `hb=absent` AND `rv=absent` AND no completion marker:
  - Run the 429 check (load `$SORCERER_REPO/prompts/tick-rate-limit-handling.md`). If 429 detected, take the throttle path on the reviewer entry (do NOT touch the parent architect's status — it stays at `architect-review-running`).
  - Else if `now - started_at < 30s`, too early — skip.
  - Else: crashed without output. Reviewer `status: failed`, parent architect `status: failed`. Escalate with `rule: architect-review-no-output`.
- `rv=present, hb=present` — reviewer mid-write; wait next tick.
- `hb=present` — still working; step 11 handles staleness (treat reviewer wizards under the same 5-min heartbeat rule as designer wizards in step 11b).

## 5e. Design-review spawn + completion

**Spawn (when a designer just transitioned to `awaiting-design-review`):**

For each `active_wizards` entry with `mode: design` and `status: awaiting-design-review` AND no `review_wizard_id` set yet:

1. Generate UUID for the reviewer.
2. `mkdir -p .sorcerer/wizards/<reviewer-id>/logs`
3. Look up the designer's `architect_id` and `sub_epic_name` (from the designer entry's existing fields).
4. Spawn the reviewer:
   ```bash
   nohup bash scripts/spawn-wizard.sh design-review \
     --wizard-id <reviewer-id> \
     --subject-id <designer-id> \
     --subject-state-dir .sorcerer/wizards/<designer-id> \
     --architect-plan-file .sorcerer/architects/<arch-id>/plan.json \
     --sub-epic-name "<sub_epic_name>" \
     > .sorcerer/wizards/<reviewer-id>/logs/spawn.txt 2>&1 &
   echo $!
   ```
5. Append to `active_wizards`:
   ```json
   {
     "id": "<reviewer-id>", "mode": "design-review", "status": "running",
     "started_at": "<ISO-8601 now>",
     "subject_id": "<designer-id>", "subject_kind": "designer",
     "review_decision": null, "review_file": null,
     "pid": <pid>, "respawn_count": 0
   }
   ```
6. Update the designer entry: `status: design-review-running`, `review_wizard_id: <reviewer-id>`.
7. Append `design-review-spawned` event.

Concurrency cap honored (same as 5d).

**Completion detection** is symmetric to 5d:
- `DESIGN_REVIEW_OK` + `review.json` present + `decision: approve` → designer `status: awaiting-tier-3`. Step 8 dispatches implement wizards from the (possibly edited) manifest.
- `decision: reject` → designer `status: failed`, escalate with `rule: design-review-rejected`.
- `DESIGN_REVIEW_FAILED` → escalate with `rule: design-review-self-reported-failure`.
- 429 → throttle path, reviewer entry only; designer stays at `design-review-running`.
- No-output crash → escalate with `rule: design-review-no-output`.
