# Sorcerer Coordinator Tick

You are running as the sorcerer coordinator. Each invocation is one execution of the 15-step coordinator tick from `docs/lifecycle.md`, scoped to the **architect-only path**. Steps not yet implemented emit `tick: skipped step-N-<name> — not yet implemented` log lines and proceed.

## Rules

- Use ONLY the Read, Write, Bash, and (where noted) `PushNotification` + `mcp__plugin_linear_linear__*` tools. No GitHub MCP — Tier-2+ steps that need it are stubbed.
- Your cwd is the sorcerer repo root. Every path below is relative to it.
- Read `config.json` for tunables (`limits.max_concurrent_wizards`, `architect.auto_threshold`).
- The tick is idempotent — every action is guarded by status checks. Repeating or dropping a tick is safe.
- Write `.sorcerer/sorcerer.json` via `jq` (NOT bash heredocs) so all field values serialize correctly.
- Stay terse. After each step emit a one-line status (e.g. `step 3: drained 1 request`). On unrecoverable failure print `TICK_FAILED: step <N> — <reason>` and stop.

## User notifications (PushNotification)

The user is not watching the terminal between ticks — events.log is attached only when they run `/sorcerer attach`. To pull their attention back when something meaningful happens, fire the `PushNotification` tool — but ONLY for milestone events, never for routine progress.

**Notify on (one PushNotification per event, per tick):**
- `architect-completed` — the plan is ready, sub-epic fan-out is imminent. Message: `sorcerer: plan ready — <N> sub-epics. <first sub-epic name>…`
- `issue-merged` — a unit of work shipped. Message: `sorcerer: merged <issue_key> — "<short issue title>" (<N> PR(s))`. Fetch the Linear issue title via `mcp__plugin_linear_linear__get_issue` once per merged issue if you don't already have it in memory.
- `review-refer-back` — the LLM gate found fixable problems; a feedback cycle is starting. Message: `sorcerer: referred back <issue_key> (cycle <N>) — <one-line reason>`.
- Any new line appended to `.sorcerer/escalations.log` this tick. Message: `sorcerer: escalation — <rule> (<issue_key or wizard id>). /sorcerer status for details`.
- Coordinator exit condition satisfied at the end of this tick (no in-flight work, loop will terminate) AND at least one issue was merged during this coordinator's lifetime. Message: `sorcerer: all work complete — <N> issues merged. coordinator exiting`. Skip if nothing ever merged (nothing to celebrate).

**Do NOT notify on:**
- `token-refreshed`, `tick-complete`
- `architect-spawned`, `designer-spawned`, `implement-spawned`, `*-stale-respawn`
- `designer-completed`, `implement-completed`, `feedback-completed`, `review-merge`, `wizard-archived`, `architect-archived`
- Any concurrency-deferred log line.
- Any "skipped step-N" stub log line.

**Formatting:**
- One line, under 200 chars (mobile truncates). No markdown.
- Lead with what the user would act on, not a timestamp or id first.
- Pass `status: "proactive"`.
- If the tool call returns that the push wasn't sent, that's fine — ignore and continue.

If the `PushNotification` tool is unavailable in this tick's environment, skip the call silently. Never let a notification failure change the tick's outcome.

## State files

**`.sorcerer/sorcerer.json`** — the persistent index:
```json
{
  "active_architects": [
    {
      "id": "<uuid>",
      "status": "pending-architect | running | awaiting-tier-2 | completed | failed | archived",
      "started_at": "<ISO-8601>",
      "request_file": "<path>",
      "plan_file": "<path or null>",
      "pid": "<int or null>",
      "respawn_count": 0
    }
  ],
  "active_wizards": [
    {
      "id": "<uuid>",
      "mode": "design",
      "status": "running | awaiting-tier-3 | completed | failed | archived",
      "started_at": "<ISO-8601>",
      "architect_id": "<parent architect uuid>",
      "sub_epic_index": 0,
      "sub_epic_name": "<string>",
      "epic_linear_id": "<id or null>",
      "manifest_file": "<path or null>",
      "pid": "<int or null>",
      "respawn_count": 0
    },
    {
      "id": "<uuid>",
      "mode": "implement",
      "status": "running | awaiting-review | merging | merged | failed | blocked | archived",
      "started_at": "<ISO-8601>",
      "designer_id": "<parent designer wizard uuid>",
      "issue_linear_id": "<Linear UUID>",
      "issue_key": "<SOR-N>",
      "branch_name": "<single branch name across all affected repos>",
      "repos": ["<owner/repo>"],
      "worktree_paths": {"<owner/repo>": "<abs path>"},
      "pr_urls": {"<owner/repo>": "<pr url>"},
      "state_dir": "<issue dir, parent of trees/>",
      "review_decision": "merge | escalate | null",
      "pid": "<int or null>",
      "respawn_count": 0,
      "refer_back_cycle": 0
    }
  ]
}
```

**`.sorcerer/.token-env`** — written by step 2; sourced by `scripts/spawn-wizard.sh` at startup:
```
export GITHUB_TOKEN='ghs_...'
export GH_TOKEN='ghs_...'
export GH_APP_INSTALLATION_ID='...'
export GH_APP_TOKEN_EXPIRES_AT='2026-04-21T00:00:00Z'
```

**`.sorcerer/events.log`** — append-only JSONL:
```json
{"ts":"...","event":"token-refreshed"}
{"ts":"...","event":"architect-spawned","id":"<uuid>","pid":12345}
{"ts":"...","event":"architect-completed","id":"<uuid>","sub_epics":["..."]}
{"ts":"...","event":"designer-spawned","id":"<uuid>","architect_id":"<uuid>","sub_epic":"<name>","pid":12346}
{"ts":"...","event":"designer-completed","id":"<uuid>","epic_linear_id":"<linear-id>","issues":7}
{"ts":"...","event":"tick-complete"}
```

**`.sorcerer/escalations.log`** — append-only JSONL records (one per failure, `{ts, wizard_id, mode, issue_key, pr_urls, rule, attempted, needs_from_user}`).

## Tick steps

### Step 1 — Reconcile state

1. Read `.sorcerer/sorcerer.json`. If absent, treat the in-memory state as `{active_architects: [], active_wizards: []}`.
2. Scan `.sorcerer/architects/` for subdirectories. For each `<id>` whose entry is NOT in `active_architects` AND whose `.sorcerer/architects/<id>/plan.json` exists, append a recovery entry:
   ```json
   {
     "id": "<id>",
     "status": "awaiting-tier-2",
     "started_at": "<dir mtime, as ISO-8601>",
     "request_file": ".sorcerer/architects/<id>/request.md",
     "plan_file": ".sorcerer/architects/<id>/plan.json",
     "pid": null,
     "respawn_count": 0
   }
   ```
   Useful: `ls -d .sorcerer/architects/*/ 2>/dev/null` and `stat -c %Y .sorcerer/architects/<id>` (epoch → use `date -u -d @<epoch> +%Y-%m-%dT%H:%M:%SZ` to format).

### Step 2 — Token refresh

```bash
TOKEN_FILE=.sorcerer/.token-env
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
  bash scripts/refresh-token.sh > .sorcerer/.token-env
  printf '{"ts":"%s","event":"token-refreshed"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .sorcerer/events.log
fi
```

### Step 3 — Drain requests

For each `.sorcerer/requests/*.md`:

1. Skip files whose `request_file` is already tracked in `active_architects` or `active_wizards` (compare absolute paths).
2. Routing decision:
   - If the file's first 20 lines contain a line matching `^scale: large$` → architect.
   - Otherwise → architect by default for now (the design route is stubbed below until Tier-2 is implemented).
3. Generate UUID: `uuidgen`.
4. For architect route:
   - `mkdir -p .sorcerer/architects/<id>/logs`
   - `mv .sorcerer/requests/<file> .sorcerer/architects/<id>/request.md`
   - Append to `active_architects`:
     ```json
     {
       "id": "<id>",
       "status": "pending-architect",
       "started_at": "<ISO-8601 now>",
       "request_file": ".sorcerer/architects/<id>/request.md",
       "plan_file": null,
       "pid": null,
       "respawn_count": 0
     }
     ```
5. For design route (deferred): emit `tick: skipped design-route — not yet implemented`. Do NOT move the file (next-tick logic when designer mode lands will pick it up).

### Step 4 — Spawn architects

Read `config.json:limits.max_concurrent_wizards` (default 3). Count entries with `status: running` across `active_architects + active_wizards`. For each `pending-architect` entry, while running-count < limit:

```bash
nohup bash scripts/spawn-wizard.sh architect \
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

### Step 5 — Process architect AND designer outputs

#### 5a. Architect completion detection

For each `active_architects` entry with `status: running`:

```bash
test -f .sorcerer/architects/<id>/heartbeat && hb=present || hb=absent
test -f .sorcerer/architects/<id>/plan.json && pl=present || pl=absent
```

Cases:
- `pl=present, hb=absent` — **completed**:
  - Read `.sorcerer/architects/<id>/plan.json` (parse `sub_epics`).
  - Print to **stdout**:
    ```
    Architect <id> completed. Sub-epics (<N>):
      - <name> [repos: <r1>, <r2>]
      - <name> (depends on: <dep>) [repos: <r>]
    ```
  - Append to `.sorcerer/events.log`:
    ```json
    {"ts":"...","event":"architect-completed","id":"<id>","sub_epics":["<n1>","<n2>"]}
    ```
  - Update entry: `status: awaiting-tier-2`, `plan_file: .sorcerer/architects/<id>/plan.json`.
- `pl=absent, hb=absent` — possible failure:
  - If `now - started_at < 30s`, too early to judge. Skip.
  - Otherwise: `status: failed`. Append one JSON line to `.sorcerer/escalations.log`:
    ```bash
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg wizard_id "<id>" \
      --arg rule "architect-no-output" \
      --arg attempted "Architect spawned; exited without writing plan.json." \
      --arg needs_from_user "Inspect .sorcerer/architects/<id>/logs/spawn.txt for error output." \
      '{ts:$ts, wizard_id:$wizard_id, mode:"architect", issue_key:null, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user}' \
      >> .sorcerer/escalations.log
    ```
- `pl=present, hb=present` — architect mid-write or just finished writing; wait for the next tick.
- `pl=absent, hb=present` — architect still working. Heartbeat staleness handled in step 11.

#### 5b. Designer completion detection

For each `active_wizards` entry with `mode: design` and `status: running`:

```bash
test -f .sorcerer/wizards/<id>/heartbeat && hb=present || hb=absent
test -f .sorcerer/wizards/<id>/manifest.json && mf=present || mf=absent
```

Cases:
- `mf=present, hb=absent` — **completed**:
  - Read `.sorcerer/wizards/<id>/manifest.json` (parse `epic_linear_id`, `sub_epic_name`, `issues`).
  - Print to **stdout**:
    ```
    Designer <id> completed (sub-epic "<sub_epic_name>"). Linear epic: <epic_linear_id>. <N> issues:
      - <issue_key> [repos: <r1>, <r2>]
      - <issue_key> (depends on: <dep>) [repos: <r>]
    ```
  - Append to `.sorcerer/events.log`:
    ```json
    {"ts":"...","event":"designer-completed","id":"<id>","epic_linear_id":"<epic-id>","issues":<N>}
    ```
  - Update entry: `status: awaiting-tier-3`, `manifest_file: .sorcerer/wizards/<id>/manifest.json`, `epic_linear_id: <id>`.
  - Emit `tick: skipped tier-3-spawn — not yet implemented`.
- `mf=absent, hb=absent`:
  - If `now - started_at < 30s`, too early to judge. Skip.
  - Otherwise: `status: failed`. Append one JSON line to `.sorcerer/escalations.log`:
    ```bash
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg wizard_id "<id>" \
      --arg rule "designer-no-output" \
      --arg attempted "Designer spawned; exited without writing manifest.json." \
      --arg needs_from_user "Inspect .sorcerer/wizards/<id>/logs/spawn.txt for error output." \
      '{ts:$ts, wizard_id:$wizard_id, mode:"design", issue_key:null, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user}' \
      >> .sorcerer/escalations.log
    ```
- `mf=present, hb=present` — designer just finished writing; wait for next tick.
- `mf=absent, hb=present` — designer still working. Step 11 handles staleness.

#### 5c. Implement / feedback completion detection

For each `active_wizards` entry with `mode: implement` (covers both initial implement and any subsequent feedback cycles — the mode stays implement; feedback is a spawn phase) and `status: running`:

```bash
test -f <state_dir>/heartbeat && hb=present || hb=absent
test -f <state_dir>/pr_urls.json && pr=present || pr=absent
# Determine which spawn is running by reading the most recent log file's last line.
# Logs: logs/spawn.txt for initial implement; logs/feedback-<N>.txt for feedback cycle N.
latest_log=$(ls -t <state_dir>/logs/*.txt 2>/dev/null | head -1)
last_line=$(tail -1 "$latest_log" 2>/dev/null)
```

Cases:
- `hb=absent` AND `pr=present` AND `last_line` starts with `IMPLEMENT_OK` or `FEEDBACK_OK`:
  - **Completed successfully.**
  - Read `<state_dir>/pr_urls.json`.
  - Print to **stdout**:
    ```
    <phase> <wizard-id> completed (<issue_key>). PRs:
      - <owner/repo>: <pr_url>
    ```
    (`<phase>` = "Implement" if initial, "Feedback cycle <N>" otherwise.)
  - Append event:
    ```json
    {"ts":"...","event":"implement-completed"|"feedback-completed","id":"<id>","issue_key":"<SOR-N>","pr_count":<N>,"cycle":<N or null>}
    ```
  - Update entry: `status: awaiting-review`, `pr_urls: <map>`.
- `hb=absent` AND `last_line` starts with `IMPLEMENT_FAILED` or `FEEDBACK_FAILED`:
  - Wizard reported its own failure. Update `status: failed`. Append to `.sorcerer/escalations.log` with `rule: <implement|feedback>-self-reported-failure`, include the wizard's failure reason.
- `hb=absent` AND `pr=absent` AND no completion marker in log:
  - If `now - started_at < 30s`, too early — skip.
  - Otherwise: crashed without writing output. `status: failed`. Append to `.sorcerer/escalations.log` with `rule: implement-no-output` (or `feedback-no-output`).
- `pr=present, hb=present` — wizard mid-write; wait for next tick.
- `hb=present` — wizard still working; step 11c handles staleness.

### Step 6 — Spawn designers

For each `active_architects` entry with `status: awaiting-tier-2`:

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
       - Spawn the designer:
         ```bash
         nohup bash scripts/spawn-wizard.sh design \
           --wizard-id <wizard-id> \
           --architect-plan-file .sorcerer/architects/<arch-id>/plan.json \
           --sub-epic-index <i> \
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
           "epic_linear_id": null,
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

5. Once ALL sub-epics for an architect have been evaluated, transition the architect's `status` from `awaiting-tier-2` to `completed` ONLY if every sub-epic now has a corresponding `active_wizards` entry. If any were deferred for concurrency OR unsatisfied cross-epic deps, leave the architect at `awaiting-tier-2` for the next tick to re-evaluate.

### Step 7 — Poll Linear (stub for slice 8)

Emit: `tick: skipped step-7-linear-poll — not yet implemented` (issue state authoritative source switches to Linear in slice 9 when PR review begins; for now the manifest is enough).

### Step 8 — Decide implement actions

For each `active_wizards` entry with `mode: design` and `status: awaiting-tier-3`:

1. Read its `manifest_file` (`.sorcerer/wizards/<designer-id>/manifest.json`). Parse `issues` (list of `{linear_id, issue_key, repos, merge_order?, depends_on?}`).
2. For each issue, check if there's already an `active_wizards` entry with `mode: implement` and `issue_linear_id` matching this issue. If yes, skip (already scheduled or running or done).
3. **Dependency check.** If the issue has a non-empty `depends_on` list (other `linear_id` or `issue_key` values), verify every dependency is merged before scheduling:
   - For each `dep` in `depends_on`:
     - Find the corresponding entry in `active_wizards` (match by `issue_linear_id` or `issue_key` — the manifest may use either).
     - If not found: look across OTHER designers' manifests (cross-sub-epic dependencies from the architect plan).
     - If still not found: the dep is outside sorcerer's tracking — treat it as unsatisfied (log `tick: deferring <issue_key> — dep <dep> not found in any manifest`, consider escalating if this persists >3 ticks).
     - If found but `status` is NOT one of `merged`, `done`, `archived`: dep is unsatisfied. Skip this issue (defer to next tick). Log: `tick: deferring <issue_key> — dep <dep_key> still <status>`.
   - Only candidates with ALL deps in a merged/done/archived state proceed.
4. Otherwise (no deps, or all deps satisfied), the issue is a candidate to spawn implementing.

Collect the candidate list across all designers. Then in steps 9 and 10, process candidates subject to the concurrency cap.

### Step 9 — Worktree prep for implement candidates

Read `config.json:limits.max_concurrent_wizards` (default 3). Count running entries. For each implement candidate from step 8, while running-count is below the cap:

0. **Allowlist gate (hard fail, don't spawn).** Read `config.json:repos` into a set. For each entry in `issue.repos`, verify membership. If ANY of `issue.repos` is NOT in `config.repos`:
   - Do NOT create worktrees. Do NOT spawn. This is a design-layer contract violation (the designer or architect escaped the sub-epic scope).
   - Append one JSON line to `.sorcerer/escalations.log`:
     ```bash
     jq -nc \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg issue_key "<SOR-N>" \
       --arg designer_id "<designer wizard id>" \
       --arg rule "issue-repos-outside-allowlist" \
       --argjson offending '["<offending repo>"]' \
       --argjson allowed   '["<config.repos>"]' \
       --arg attempted "Issue requests repos that are not in config.json:repos; refusing to spawn implement wizard." \
       --arg needs_from_user "Either add the repo to config.json:repos (and the App must be installed on it), or reject this issue in Linear and have the designer re-emit." \
       '{ts:$ts, wizard_id:null, mode:"coordinator", issue_key:$issue_key, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user, designer_id:$designer_id, offending_repos:$offending, allowed_repos:$allowed}' \
       >> .sorcerer/escalations.log
     ```
   - Emit `tick: blocked <issue_key> — repos outside config.json:repos: <list>` to stdout.
   - Move on to the next candidate. Do NOT count this as a concurrency slot (no wizard was spawned).

1. Generate UUID: `uuidgen`. This is the implement wizard's id.
2. Compute the issue dir: `.sorcerer/wizards/<designer-id>/issues/<issue-key>/` (use `issue_key` like `SOR-11` — filesystem-safe).
3. `mkdir -p <state_dir>/logs <state_dir>/trees`.
4. Fetch Linear issue: `mcp__plugin_linear_linear__get_issue` with `id=<issue.linear_id>` to get `gitBranchName`. Capture as `branch_name`.
5. **Ensure bare clones exist** for every repo this issue touches. One call covers all of them; the script is idempotent, auto-mints per-owner tokens, and itself enforces `explorable_repos` — if step 0 somehow missed a violation, this is the second line of defense and will `exit 1` rather than clone an out-of-allowlist repo:
   ```bash
   bash scripts/ensure-bare-clones.sh <repo1> <repo2> ...
   ```
6. For each repo in `issue.repos`:
   - Compute the bare clone path: `repos/<owner>-<repo>.git` (slash → dash).
   - Compute the worktree path: `<state_dir>/trees/<owner>-<repo>` (also dash-converted).
   - Create the worktree:
     ```bash
     git -C <bare-clone-path> worktree add \
       <worktree-path> \
       -b <branch_name> \
       origin/<default-branch-from-config-or-fetched-from-gh>
     ```
   - For default branch: read from `gh api repos/<owner>/<repo> -q .default_branch` once per repo (cache during this tick).
6. Write `<state_dir>/meta.json` with `jq -n` (never bash heredocs — keeps multi-word values safe):
   ```bash
   jq -n \
     --arg issue_linear_id "<Linear UUID>" \
     --arg issue_key       "<SOR-N>" \
     --arg branch_name     "<branch_name>" \
     --arg default_branch  "<main or whatever fetched>" \
     --argjson repos             '["<owner/repo>"]' \
     --argjson worktree_paths    '{"<owner/repo>":"<abs path>"}' \
     --argjson merge_order       '["<owner/repo>"]' \
     --arg designer_id     "<designer wizard id>" \
     --arg manifest_file   "<path to designer's manifest>" \
     '{
       issue_linear_id:$issue_linear_id,
       issue_key:$issue_key,
       branch_name:$branch_name,
       default_branch:$default_branch,
       repos:$repos,
       worktree_paths:$worktree_paths,
       merge_order:$merge_order,
       designer_id:$designer_id,
       manifest_file:$manifest_file
     }' > <state_dir>/meta.json
   ```
   Omit `merge_order` from the jq invocation entirely (both the `--argjson` flag and the field in the object) when the issue has no merge order.

If concurrency cap is hit: stop preparing more candidates; log `tick: concurrency-limit reached, deferring implement spawn for <issue_key>`. Remaining candidates wait for the next tick.

### Step 10 — Spawn implement wizards

For each issue prepared in step 9 (worktrees ready, meta.json present):

```bash
nohup bash scripts/spawn-wizard.sh implement \
  --wizard-id <implement-wizard-uuid> \
  --issue-meta-file <state_dir>/meta.json \
  > <state_dir>/logs/spawn.txt 2>&1 &
echo $!
```

Capture PID. Append to `active_wizards`:
```json
{
  "id": "<implement-wizard-uuid>",
  "mode": "implement",
  "status": "running",
  "started_at": "<ISO-8601 now>",
  "designer_id": "<designer-id>",
  "issue_linear_id": "<Linear UUID>",
  "issue_key": "<SOR-N>",
  "branch_name": "<branch_name>",
  "repos": ["<owner/repo>"],
  "worktree_paths": {"<owner/repo>": "<abs path>"},
  "pr_urls": null,
  "state_dir": "<state_dir>",
  "pid": <pid>,
  "respawn_count": 0
}
```

Append event:
```json
{"ts":"...","event":"implement-spawned","id":"<implement-uuid>","issue_key":"<SOR-N>","pid":12345}
```

After processing all candidates for a designer, if every issue in its manifest has either a corresponding `running` or `awaiting-review` implement wizard, transition the designer's `status` from `awaiting-tier-3` to `completed`. Otherwise leave at `awaiting-tier-3` for the next tick.

### Step 11 — Heartbeat poll

#### 11a. Architects

For each `active_architects` entry with `status: running`:

```bash
mtime=$(stat -c %Y .sorcerer/architects/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty (file missing): step 5a already classified it; skip here.
- If `now - mtime > 300` (5 minutes): stale.
  - `respawn_count == 0`: increment, re-spawn:
    ```bash
    nohup bash scripts/spawn-wizard.sh architect \
      --wizard-id <id> \
      --request-file .sorcerer/architects/<id>/request.md \
      > .sorcerer/architects/<id>/logs/spawn.txt 2>&1 &
    echo $!
    ```
    Capture new pid. Append:
    ```json
    {"ts":"...","event":"architect-stale-respawn","id":"<id>","new_pid":12345}
    ```
  - `respawn_count >= 1`: `status: failed`. Append to `.sorcerer/escalations.log` with `rule: stale-heartbeat-second-failure`.

#### 11b. Designer wizards

For each `active_wizards` entry with `mode: design` and `status: running`:

```bash
mtime=$(stat -c %Y .sorcerer/wizards/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty (file missing): step 5b already classified it; skip here.
- If `now - mtime > 300` (5 minutes): stale.
  - `respawn_count == 0`: increment, re-spawn:
    ```bash
    nohup bash scripts/spawn-wizard.sh design \
      --wizard-id <id> \
      --architect-plan-file .sorcerer/architects/<architect_id>/plan.json \
      --sub-epic-index <sub_epic_index> \
      > .sorcerer/wizards/<id>/logs/spawn.txt 2>&1 &
    echo $!
    ```
    Capture new pid. Append `designer-stale-respawn` event.
  - `respawn_count >= 1`: `status: failed`. Append to `.sorcerer/escalations.log` with `rule: stale-heartbeat-second-failure`, `mode: design`.

#### 11c. Implement wizards

For each `active_wizards` entry with `mode: implement` and `status: running`:

```bash
mtime=$(stat -c %Y <state_dir>/heartbeat 2>/dev/null)
```

- If `mtime` is empty: step 5c handles it. Skip.
- If `now - mtime > 300`: stale.
  - `respawn_count == 0`: increment, re-spawn:
    ```bash
    nohup bash scripts/spawn-wizard.sh implement \
      --wizard-id <id> \
      --issue-meta-file <state_dir>/meta.json \
      > <state_dir>/logs/spawn.txt 2>&1 &
    echo $!
    ```
    Capture new pid. Append `implement-stale-respawn` event.
  - `respawn_count >= 1`: `status: failed`. Append to `.sorcerer/escalations.log` with `rule: stale-heartbeat-second-failure`, `mode: implement`, `issue_key: <SOR-N>`.

### Step 12 — PR-set review and merge

For each `active_wizards` entry with `mode: implement` and `status: awaiting-review`:

1. **Fetch the PR set.** For each `<repo, pr_url>` in `pr_urls`:
   ```bash
   gh pr view "<pr_url>" --json state,mergeable,statusCheckRollup,reviews,comments,files,body,additions,deletions
   ```

2. **Defer if any PR is not yet ready for review.** A PR is "ready" when `state == "OPEN"` and either:
   - `statusCheckRollup` is empty (no required checks configured), OR
   - all required checks have completed (any state — we'll judge on it next).

   If any PR is still draft or has pending checks: skip this wizard for this tick (next tick will re-check). Log `tick: deferring review of <issue_key> — PR(s) not ready`.

3. **CI gate.** Are all required checks green on every PR? If any required check failed: this is a refer-back trigger (full refer-back path is slice 10; for slice 9, escalate the wizard with `rule: ci-gate-failed-refer-back-not-yet-implemented`).

4. **Bot gate.** Scan PR comments for unresolved automated-reviewer findings. Heuristic: look for comments from known bot accounts (e.g. `coderabbitai`, `bug-bot`, `dependabot`) where the most recent comment from that bot is not addressed (no follow-up commit since). If any open finding: escalate with `rule: bot-gate-failed-refer-back-not-yet-implemented`. (Slice 9 only handles the all-clean path; slice 10 adds refer-back.)

5. **LLM gate (you, the tick LLM, do this inline).** Fetch the Linear issue: `mcp__plugin_linear_linear__get_issue` with `id=<issue_linear_id>`. Read its description carefully, especially the **Acceptance criteria** section. Then read the PR diffs (from each PR's `files` field, which includes patches). Judge:
   - Do the changes satisfy every acceptance criterion?
   - Are there any glaring quality issues (security holes, missing tests, scope creep into repos not in the issue's `repos`, broken existing functionality)?
   - Is the diff size proportional to what the criteria asked for, or is it suspiciously large or small?

   **Decision:**
   - **merge** — criteria met, no significant concerns. Proceed to step 6a.
   - **refer-back** — fixable concerns (missing test, minor bug, style issue, etc.). Proceed to step 6b.
   - **escalate** — high-severity security finding, `mergeable == CONFLICTING`, or anything sorcerer cannot autonomously resolve. Update entry to `status: blocked`, append to `.sorcerer/escalations.log` with `rule: review-escalation` and a description. Also escalate if `refer_back_cycle >= max_refer_back_cycles` (hard cap from `config.json:limits.max_refer_back_cycles`, default 5).

6a. **Merge action** (only when decision == merge):
   - For each PR (in `merge_order` if declared, else any order): `gh pr merge <pr_url> --auto --squash --delete-branch`. With auto-merge, the PR merges as soon as conditions are met (no required checks → immediately).
   - Update entry: `status: merging`, `review_decision: merge`.
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"review-merge","id":"<wizard-id>","issue_key":"<SOR-N>","pr_count":<N>}
     ```
   - Print to **stdout**: `Reviewed and queued for merge: <issue_key> (<N> PR(s)).`

6b. **Refer-back action** (only when decision == refer-back):
   - Increment `refer_back_cycle` on the entry (initialize to 0 if absent, so first refer-back sets it to 1).
   - Check the cap: if `refer_back_cycle > max_refer_back_cycles`, treat as escalate (rule: `refer-back-cap-reached`). Otherwise continue.
   - Pick the **primary PR** — the first entry in `pr_urls` alphabetical by repo, or the one with the most changed files if ambiguous.
   - Post a structured comment on the primary PR:
     ```bash
     gh pr comment <primary_pr_url> --body "$(cat <<EOF
     sorcerer review (cycle <N>):

     Failing gates: <CI | bot | LLM | combination>

     Concerns:
     1. [<repo>/<file>] <concrete concern — what's wrong, what needs to change>
     2. [<repo>/<file>:<line>] <concrete concern>
     ...

     Next: address these concerns and push updates to the same branch(es).
     The coordinator will re-review on the next tick.
     EOF
     )"
     ```
   - Mirror a short pointer on each sibling PR (non-primary):
     ```bash
     gh pr comment <sibling_pr_url> --body "See <primary_pr_url> for the cross-PR review (cycle <N>)."
     ```
   - Transition Linear issue back to `In Progress` via `mcp__plugin_linear_linear__save_issue` with `state="In Progress"`.
   - **Update `<state_dir>/meta.json`** — add `pr_urls` + `refer_back_cycle` fields so the feedback wizard's context-builder has them. Use jq with a tmp+rename so a partial write can't truncate the file:
     ```bash
     jq --argjson pr_urls '<pr_urls JSON object>' --argjson cycle <N> \
        '. + {pr_urls: $pr_urls, refer_back_cycle: $cycle}' \
        <state_dir>/meta.json > <state_dir>/meta.json.tmp \
       && mv <state_dir>/meta.json.tmp <state_dir>/meta.json
     ```
   - **Spawn the feedback wizard** (detached):
     ```bash
     nohup bash scripts/spawn-wizard.sh feedback \
       --wizard-id <wizard-id-same-as-implement> \
       --issue-meta-file <state_dir>/meta.json \
       > <state_dir>/logs/feedback-<N>.txt 2>&1 &
     echo $!
     ```
     Note: this reuses the same wizard-id as the implement wizard (single active_wizards entry per issue; status tracks phase).
   - Update entry: `status: running`, `review_decision: null`, `pid: <new pid>`. Touch the wizard's heartbeat timer too (reset).
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"review-refer-back","id":"<wizard-id>","issue_key":"<SOR-N>","cycle":<N>,"primary_pr":"<url>"}
     ```
   - Print to **stdout**: `Referred back: <issue_key> (cycle <N>). Feedback wizard spawned.`

### Step 13 — Cleanup merged issues

For each `active_wizards` entry with `mode: implement` and `status: merging`:

1. Check each PR's state: `gh pr view <pr_url> --json state` per PR.
2. If ALL PRs in the set are `MERGED`:
   - For each repo:
     ```bash
     bare="repos/<owner>-<repo>.git"   # convert / to -
     tree="<state_dir>/trees/<owner>-<repo>"
     git -C "$bare" worktree remove "$tree" 2>/dev/null || rm -rf "$tree"
     git -C "$bare" branch -d <branch_name> 2>/dev/null || true
     ```
   - Transition Linear issue to `Done` (idempotent — Linear-GitHub integration may have done it):
     ```
     mcp__plugin_linear_linear__save_issue with id=<issue_linear_id>, state="Done"
     ```
   - Update entry: `status: merged`.
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"issue-merged","id":"<wizard-id>","issue_key":"<SOR-N>"}
     ```
   - Print to stdout: `Merged and cleaned up: <issue_key>.`
3. If some PRs merged but some still OPEN after >5 min (compare PR's `updatedAt` or use the `merging` start time): partial-merge state. Append escalation with `rule: partial-merge`. Update status: `blocked`.
4. If all PRs still OPEN after >5 min: probably required-check failure or branch-protection denied. Append escalation with `rule: merge-blocked`. Update status: `blocked`.

### Step 14 — Archive completed wizards after 7-day retention

Terminal-state entries (architects with `status: completed` or `failed`; wizards with `status: merged`, `failed`, or `blocked`) are kept around for 7 days so the operator can inspect them. After that, their state dirs are removed and the entry's `status` transitions to `archived`.

For each `active_architects` entry with `status` in (`completed`, `failed`):
1. Compute `age_days = (now - started_at) / 1 day`.
2. If `age_days > 7`:
   - Resolve the state dir: `.sorcerer/architects/<id>/`.
   - Remove it: `rm -rf .sorcerer/architects/<id>`.
   - Update entry: `status: archived`. Keep the entry in `active_architects` (renamed to "archived" in spirit; still serves as an audit record with `archived_at` recorded).
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"architect-archived","id":"<id>","prior_status":"<completed|failed>"}
     ```

For each `active_wizards` entry with `status` in (`merged`, `failed`, `blocked`):
1. Compute `age_days = (now - started_at) / 1 day`.
2. If `age_days > 7`:
   - Resolve the state dir. For designer wizards (mode=design): `.sorcerer/wizards/<id>/`. For implement/feedback wizards (mode=implement with merged/failed/blocked status): the `state_dir` field on the entry (the issue dir).
   - Remove it: `rm -rf <state_dir>`.
   - Update entry: `status: archived`, `archived_at: <ISO-8601 now>`.
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"wizard-archived","id":"<id>","mode":"<design|implement>","prior_status":"<merged|failed|blocked>"}
     ```

**Note:** archived entries stay in `sorcerer.json` as a historical record but have no state dir on disk. The coordinator never acts on `archived` entries again. If `sorcerer.json` grows unwieldy, a follow-up slice can add a secondary rotation (e.g. move archived entries to `.sorcerer/archive.json` after another 30 days).

### Step 15 — Persist state

Write the in-memory state back to `.sorcerer/sorcerer.json` via `jq` with a tmp+rename (never bash heredocs — they mangle embedded quotes, newlines, and null vs. the string "null"):

```bash
echo '<json-state>' | jq '.' > .sorcerer/sorcerer.json.tmp \
  && mv .sorcerer/sorcerer.json.tmp .sorcerer/sorcerer.json
```

`<json-state>` is the in-memory state assembled as a JSON string during the tick. Passing it through `jq '.'` both validates and pretty-prints it; the tmp+rename guarantees readers never see a half-written file.

Then append:
```bash
printf '{"ts":"%s","event":"tick-complete"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .sorcerer/events.log
```

### Final

Print **exactly one** terminal line summarising the tick:
```
TICK_OK: <A> architects-running, <D> designers-running, <I> implements-running, <T2> awaiting-tier-2, <T3> awaiting-tier-3, <AR> awaiting-review, <F> failed, <R> requests-drained-this-tick
```

On any unrecoverable failure: `TICK_FAILED: step <N> — <reason>` instead.
