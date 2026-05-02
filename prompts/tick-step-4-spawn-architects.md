# Step 4 — Spawn architects

## 4a. File Linear epic issue at submit time

Before spawning each architect, give the request a Linear-side container so operators can see submitted-but-not-yet-architected work in Linear (and so designer sub-issues have a `parentId` to link to).

For each `active_architects` entry with `status: pending-architect` AND `epic_linear_id == null`:

- Read `.sorcerer/architects/<id>/request.md`.
- Read `<project-root>/.sorcerer/config.json:linear.project_uuid` for the target project.
- Derive the **title**: first non-empty, non-whitespace line of `request.md`, stripped of leading `#` chars; cap to ~80 chars; prefix with `Epic: `.
- Derive the **description**: a markdown body containing (a) `## Request` section with the full request text quoted, (b) a footer line `<!-- sorcerer architect <arch-id-short> request <ts> -->` so the issue is identifiable as architect-emitted.
- Call `mcp__plugin_linear_linear__save_issue` with:
  - `title`: from above.
  - `description`: from above.
  - `project`: `<config.json:linear.project_uuid>`.
  - `state`: `"Todo"`.
  - `labels`: omit. **Do NOT pass `parentId`** — request issues are top-level epics.
- Capture the response's `id` (e.g. `SOR-540`).
- Update the architect entry: `epic_linear_id: "<id>"`. Atomic write of `sorcerer.json`.
- Append event:
  ```json
  {"ts":"...","event":"epic-issue-filed","architect_id":"<arch-id>","epic_linear_id":"<id>","stage":"submit"}
  ```

If `save_issue` fails: append an `epic-file-failed` escalation, leave `epic_linear_id` null, and proceed to the spawn step below — the architect can still run; step 6 sub-step 0 will retry the create path on a later tick.

If `epic_linear_id` is already non-null, skip — idempotent.

## 4b. Architect spawn

Read `config.json:limits.max_concurrent_wizards` (default 3). Count entries with `status: running` across `active_architects + active_wizards`. For each `pending-architect` entry, while running-count < limit:

```bash
nohup bash "$SORCERER_REPO/scripts/spawn-wizard.sh" architect \
  --wizard-id <id> \
  --request-file .sorcerer/architects/<id>/request.md \
  > .sorcerer/architects/<id>/logs/spawn.txt 2>&1 &
echo $!
```

Capture the PID printed by `echo $!`. Update the entry: `status: running`, `pid: <pid>`, `started_at: <ISO-8601 now>`. Append:
```json
{"ts":"...","event":"architect-spawned","id":"<id>","pid":12345}
```

If at the concurrency ceiling, emit `tick: concurrency-limit reached, deferring spawn of <id>`. Leave status `pending-architect`.
