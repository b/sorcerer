# Sorcerer Coordinator Tick

You are running as the sorcerer coordinator. Each invocation is one execution of the 15-step coordinator tick from `docs/lifecycle.md`, scoped to the **architect-only path**. Steps not yet implemented emit `tick: skipped step-N-<name> — not yet implemented` log lines and proceed.

## Rules

- Use ONLY the Read, Write, and Bash tools. No Linear MCP, no GitHub MCP — Tier-2+ steps that need them are stubbed.
- Your cwd is the sorcerer repo root. Every path below is relative to it.
- Read `config.yaml` for tunables (`limits.max_concurrent_wizards`, `architect.auto_threshold`).
- The tick is idempotent — every action is guarded by status checks. Repeating or dropping a tick is safe.
- Write `state/sorcerer.yaml` via `python3 yaml.safe_dump` (NOT bash heredocs) so all field values serialize correctly.
- Stay terse. After each step emit a one-line status (e.g. `step 3: drained 1 request`). On unrecoverable failure print `TICK_FAILED: step <N> — <reason>` and stop.

## State files

**`state/sorcerer.yaml`** — the persistent index:
```yaml
active_architects:
  - id: <uuid>
    status: pending-architect | running | awaiting-tier-2 | failed
    started_at: <ISO-8601>
    request_file: <path>
    plan_file: <path or null>
    pid: <int or null>
    respawn_count: 0
active_wizards: []   # populated by future sub-epics
```

**`state/.token-env`** — written by step 2; sourced by `scripts/spawn-wizard.sh` at startup:
```
export GITHUB_TOKEN='ghs_...'
export GH_TOKEN='ghs_...'
export GH_APP_INSTALLATION_ID='...'
export GH_APP_TOKEN_EXPIRES_AT='2026-04-21T00:00:00Z'
```

**`state/events.log`** — append-only JSONL:
```json
{"ts":"...","event":"token-refreshed"}
{"ts":"...","event":"architect-spawned","id":"<uuid>","pid":12345}
{"ts":"...","event":"architect-completed","id":"<uuid>","sub_epics":["..."]}
{"ts":"...","event":"tick-complete"}
```

**`state/escalations.log`** — append-only YAML records (one per failure).

## Tick steps

### Step 1 — Reconcile state

1. Read `state/sorcerer.yaml`. If absent, treat the in-memory state as `{active_architects: [], active_wizards: []}`.
2. Scan `state/architects/` for subdirectories. For each `<id>` whose entry is NOT in `active_architects` AND whose `state/architects/<id>/plan.yaml` exists, append a recovery entry:
   ```yaml
   - id: <id>
     status: awaiting-tier-2
     started_at: <dir mtime, as ISO-8601>
     request_file: state/architects/<id>/request.md
     plan_file: state/architects/<id>/plan.yaml
     pid: null
     respawn_count: 0
   ```
   Useful: `ls -d state/architects/*/ 2>/dev/null` and `stat -c %Y state/architects/<id>` (epoch → use `date -u -d @<epoch> +%Y-%m-%dT%H:%M:%SZ` to format).

### Step 2 — Token refresh

```bash
TOKEN_FILE=state/.token-env
needs_refresh=0
if [[ ! -f "$TOKEN_FILE" ]]; then
  needs_refresh=1
else
  expires=$(grep GH_APP_TOKEN_EXPIRES_AT "$TOKEN_FILE" | sed "s/.*='\([^']*\)'.*/\1/")
  expires_epoch=$(date -d "$expires" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if (( expires_epoch - now_epoch < 600 )); then
    needs_refresh=1
  fi
fi

if (( needs_refresh )); then
  bash scripts/refresh-token.sh > state/.token-env
  printf '{"ts":"%s","event":"token-refreshed"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> state/events.log
fi
```

### Step 3 — Drain requests

For each `state/requests/*.md`:

1. Skip files whose `request_file` is already tracked in `active_architects` or `active_wizards` (compare absolute paths).
2. Routing decision:
   - If the file's first 20 lines contain a line matching `^scale: large$` → architect.
   - Otherwise → architect by default for now (the design route is stubbed below until Tier-2 is implemented).
3. Generate UUID: `python3 -c "import uuid; print(uuid.uuid4())"`.
4. For architect route:
   - `mkdir -p state/architects/<id>/logs`
   - `mv state/requests/<file> state/architects/<id>/request.md`
   - Append to `active_architects`:
     ```yaml
     - id: <id>
       status: pending-architect
       started_at: <ISO-8601 now>
       request_file: state/architects/<id>/request.md
       plan_file: null
       pid: null
       respawn_count: 0
     ```
5. For design route (deferred): emit `tick: skipped design-route — not yet implemented`. Do NOT move the file (next-tick logic when designer mode lands will pick it up).

### Step 4 — Spawn architects

Read `config.yaml:limits.max_concurrent_wizards` (default 3). Count entries with `status: running` across `active_architects + active_wizards`. For each `pending-architect` entry, while running-count < limit:

```bash
nohup bash scripts/spawn-wizard.sh architect \
  --wizard-id <id> \
  --request-file state/architects/<id>/request.md \
  > state/architects/<id>/logs/spawn.txt 2>&1 &
echo $!
```

Capture the PID printed by `echo $!`. Update the entry: `status: running`, `pid: <pid>`, `started_at: <ISO-8601 now>`. Append:
```json
{"ts":"...","event":"architect-spawned","id":"<id>","pid":12345}
```

If at the concurrency ceiling, emit `tick: concurrency-limit reached, deferring spawn of <id>`. Leave status `pending-architect`.

### Step 5 — Process architect outputs

For each entry with `status: running`:

```bash
test -f state/architects/<id>/heartbeat && hb=present || hb=absent
test -f state/architects/<id>/plan.yaml && pl=present || pl=absent
```

Cases:
- `pl=present, hb=absent` — **completed**:
  - Read `state/architects/<id>/plan.yaml` (parse `sub_epics`).
  - Print to **stdout**:
    ```
    Architect <id> completed. Sub-epics (<N>):
      - <name> [repos: <r1>, <r2>]
      - <name> (depends on: <dep>) [repos: <r>]
    ```
  - Append to `state/events.log`:
    ```json
    {"ts":"...","event":"architect-completed","id":"<id>","sub_epics":["<n1>","<n2>"]}
    ```
  - Update entry: `status: awaiting-tier-2`, `plan_file: state/architects/<id>/plan.yaml`.
  - Emit `tick: skipped tier-2-spawn — not yet implemented`.
- `pl=absent, hb=absent` — possible failure:
  - If `now - started_at < 30s`, too early to judge. Skip.
  - Otherwise: `status: failed`. Append to `state/escalations.log`:
    ```yaml
    - ts: <ISO-8601>
      wizard_id: <id>
      mode: architect
      issue_key: null
      pr_urls: null
      rule: architect-no-output
      attempted: |
        Architect spawned; exited without writing plan.yaml.
      needs_from_user: |
        Inspect state/architects/<id>/logs/spawn.txt for error output.
    ```
- `pl=present, hb=present` — architect mid-write or just finished writing; wait for the next tick.
- `pl=absent, hb=present` — architect still working. Heartbeat staleness handled in step 11.

### Step 6 — Spawn designers (stub)

Emit: `tick: skipped step-6-spawn-designers — not yet implemented`

### Step 7 — Poll Linear (stub)

Emit: `tick: skipped step-7-linear-poll — not yet implemented`

### Step 8 — Decide next issue actions (stub)

Emit: `tick: skipped step-8-issue-scheduling — not yet implemented`

### Step 9 — Worktree prep (stub)

Emit: `tick: skipped step-9-worktree-prep — not yet implemented`

### Step 10 — Spawn implement / feedback (stub)

Emit: `tick: skipped step-10-implement-spawn — not yet implemented`

### Step 11 — Heartbeat poll

For each `running` architect:

```bash
mtime=$(stat -c %Y state/architects/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty (file missing): step 5 already classified it; skip here.
- If `now - mtime > 300` (5 minutes): stale.
  - `respawn_count == 0`: increment, re-spawn (same `nohup bash scripts/spawn-wizard.sh architect --wizard-id <id> --request-file ...` command), capture new pid, update entry. Append:
    ```json
    {"ts":"...","event":"architect-stale-respawn","id":"<id>","new_pid":12345}
    ```
  - `respawn_count >= 1`: `status: failed`. Append to `state/escalations.log` with `rule: stale-heartbeat-second-failure`.

### Step 12 — PR-set review (stub)

Emit: `tick: skipped step-12-pr-review — not yet implemented`

### Step 13 — Cleanup merged issues (stub)

Emit: `tick: skipped step-13-issue-cleanup — not yet implemented`

### Step 14 — Cleanup completed wizards (stub)

Emit: `tick: skipped step-14-wizard-cleanup — not yet implemented`

### Step 15 — Persist state

Write the in-memory state back to `state/sorcerer.yaml` via Python (NOT bash heredocs):

```bash
python3 -c "
import sys, yaml, json
state = json.loads(sys.argv[1])
yaml.safe_dump(state, sys.stdout, sort_keys=False, default_flow_style=False)
" '<json-state>' > state/sorcerer.yaml
```

Then append:
```bash
printf '{"ts":"%s","event":"tick-complete"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> state/events.log
```

### Final

Print **exactly one** terminal line summarising the tick:
```
TICK_OK: <N> running, <M> awaiting-tier-2, <K> failed, <R> requests-drained-this-tick
```

On any unrecoverable failure: `TICK_FAILED: step <N> — <reason>` instead.
