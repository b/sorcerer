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
- `pr-orphan-adopted` — sorcerer found an open bot-authored PR with no live wizard claim and synthesized an `awaiting-review` entry for it. Message: `sorcerer: adopted orphan PR <repo>#<num> (<issue_key or branch>) — review gate next tick`. State drift is worth surfacing because adoption usually means an entry was lost from `sorcerer.json`; one notification per adoption per tick.
- `coordinator-paused` event (new `paused_until` set this tick due to rate-limit storm). Message: `sorcerer: paused ~15m — rate limit hit on <N> spawns. Will auto-resume`.
- Coordinator exit condition satisfied at the end of this tick (no in-flight work, loop will terminate) AND at least one issue was merged during this coordinator's lifetime. Message: `sorcerer: all work complete — <N> issues merged. coordinator exiting`. Skip if nothing ever merged (nothing to celebrate).

**Do NOT notify on:**
- `token-refreshed`, `tick-complete`
- `architect-spawned`, `designer-spawned`, `implement-spawned`, `*-stale-respawn`
- `designer-completed`, `implement-completed`, `feedback-completed`, `review-merge`, `wizard-archived`, `architect-archived`
- `wizard-throttled`, `wizard-resumed`, `coordinator-resumed`, `provider-throttled` — individual throttles and single-provider rotations are routine recoverable events; only the coordinator-level `coordinator-paused` (which means EVERY slot is exhausted or ambient auth is the only option) warrants attention.
- Any concurrency-deferred log line.
- Any "skipped step-N" stub log line.

**Formatting:**
- One line, under 200 chars (mobile truncates). No markdown.
- Lead with what the user would act on, not a timestamp or id first.
- Pass `status: "proactive"`.
- If the tool call returns that the push wasn't sent, that's fine — ignore and continue.

If the `PushNotification` tool is unavailable in this tick's environment, skip the call silently. Never let a notification failure change the tick's outcome.

## Max wall-clock age (runaway-wizard kill switch)

A wizard's `claude -p` subprocess can get stuck in a long-running shell construct that never terminates — the most common case observed in the wild is an LLM improvising a `bash until [[ <condition> ]]; do sleep; done` loop where `<condition>` can't become true. Heartbeat may still be touched (if the loop touches it) and PID is alive, so none of step 5's classifiers or step 11's stale-heartbeat check fires. The wizard just burns forever, blocking its own dispatch slot and gating downstream work.

Coordinator enforces a hard wall-clock ceiling per mode via `config.json:limits.max_wizard_age_seconds`. Defaults (seconds):

| mode              | default | rationale                               |
|-------------------|---------|-----------------------------------------|
| architect         | 1800    | 30 min; plans don't need longer         |
| architect-review  |  900    | 15 min; reviewing plan.json is small    |
| design            | 2700    | 45 min; Linear writes + repo survey     |
| design-review     | 1200    | 20 min; walking issues, small edits     |
| implement         | 10800   | 3 hours; real cross-repo work           |
| feedback          | 3600    | 1 hour; targeted fixes                  |
| rebase            | 1800    | 30 min; conflict resolution             |

**Kill helper** (used below in step 11):

```bash
# Given a pid, SIGTERM it, wait up to 5 s, SIGKILL if still alive.
kill_wizard_pid() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "null" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
}
```

**Runtime check** (applied in every step 11 sub-section BEFORE the heartbeat-stale check):

```bash
# For a wizard entry with known mode + started_at + pid:
max_age=$(jq -r --arg m "<mode>" '.limits.max_wizard_age_seconds[$m] // 3600' .sorcerer/config.json 2>/dev/null || echo 3600)
age=$(( $(date +%s) - $(date -u -d "<started_at>" +%s) ))
if (( age > max_age )); then
  kill_wizard_pid "<pid>"
  # Mark failed (no respawn — at this age the bug is in the run itself, not
  # something a fresh spawn would fix), escalate, append event:
  bash $SORCERER_REPO/scripts/append-escalation.sh "<id>" "<mode>" "<issue_key or null>" \
    "wizard-max-age-exceeded" \
    "Wizard ran <age>s (>= max_age <max_age>s) and was SIGTERM'd. Likely stuck in a non-terminating shell loop or a hung MCP call." \
    "Inspect <state_dir>/logs/*.txt. If the LLM improvised an impossible-exit loop, fix the prompt; if transient, re-submit."
  printf '{"ts":"%s","event":"wizard-killed-max-age","id":"%s","mode":"%s","age_seconds":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "<id>" "<mode>" "$age" >> .sorcerer/events.log
  # Skip the remaining step-11 logic for this entry.
fi
```

**Why kill + fail instead of kill + respawn**: a wizard that hit its wall-clock ceiling has already been through any 429/529 throttle windows and any heartbeat-respawn cycles. At this age, the bug is almost always in the wizard's run itself (improvised infinite loop, stuck MCP call, etc.) — a fresh spawn would likely hit the same issue. Human needs to look at the log. One PushNotification fires via the escalation.

## Process liveness (dead-pid detection)

Every spawn captures the `bash scripts/spawn-wizard.sh ...` subprocess PID into the entry's `pid` field. When that subprocess exits — cleanly, on crash, or on kill — the PID is no longer alive. An on-disk `heartbeat` file from an earlier phase of the run can linger AFTER the process dies, so `test -f heartbeat` alone isn't sufficient to conclude "wizard is still working."

**Helper used throughout step 5 and step 11**:

```bash
# Returns 0 if the entry is still an active OS process, 1 if the PID is gone.
is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" && "$pid" != "null" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}
```

**Usage in step 5 case-classification**: before applying the heartbeat-based cases below, compute an *effective* heartbeat state:

```bash
test -f <heartbeat> && hb_file=present || hb_file=absent
if is_pid_alive "<pid>"; then
  hb="$hb_file"
else
  # Process is gone. Any heartbeat file is leftover from before the crash.
  # Force the classifier into marker-based mode so we don't wait 5 minutes
  # for step 11's staleness gate to pick up a dead wizard.
  hb=absent
fi
```

From here the existing `hb=present` / `hb=absent` branches work unchanged — a dead PID with a leftover heartbeat routes through the same paths as a clean "heartbeat was removed on exit".

## PR-set recovery (for implement / feedback / rebase wizards)

A wizard can do real work — push commits, open PRs — and then die before writing its completion marker or removing the heartbeat (crash, OOM, the claude subprocess itself hitting a limit mid-sentence, machine reboot, etc). The cheap-but-wrong move is to mark the entry `failed` and escalate. The right move is to check GitHub first: **if every repo in the wizard's `repos` has an open PR on its `branch_name`, the wizard's output is already durable — reconstruct `pr_urls.json` from `gh` and transition the entry to `awaiting-review`**. Step 12 will re-evaluate the set and do the appropriate next thing (merge / refer-back / rebase) on its own terms.

**Helper** (used in step 5c's "crashed without writing output" path and step 11c's stale-heartbeat respawn path):

- `bash $SORCERER_REPO/scripts/discover-pr-set.sh <branch_name> <repo1> [<repo2> ...]`
  - On success (every named repo has an open PR for `<branch_name>`): prints `{"<owner/name>": "<pr_url>", ...}` JSON to stdout, exits 0.
  - On any missing PR (incomplete set): prints nothing, exits 1.
  - Repos are passed in `github.com/owner/name` form (the prefix is stripped internally).

**Recovery action** (when discover-pr-set succeeded — write pr_urls.json, transition to awaiting-review, append event):

```bash
echo "$pr_set_json" > "$state_dir/pr_urls.json"
# Update the entry: status=awaiting-review, pr_urls=<pr_set_json>
printf '{"ts":"%s","event":"pr-set-recovered","id":"%s","issue_key":"%s","pr_count":%d,"source":"<step5|step11>"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wizard_id" "$issue_key" "$pr_count" >> .sorcerer/events.log
```

This is only applicable to `mode: implement | feedback | rebase` wizards — the ones that have `branch_name` + `repos` + `state_dir` fields. Architect and designer wizards produce plan/manifest files locally and don't have a PR fallback, so they stay on the original failed/respawn path.

## Orphan-PR adoption (for PRs whose owning wizard was pruned)

`discover_pr_set` above only helps wizards that are *still* in `active_wizards` but went stale. It does NOT help when the wizard's `active_wizards` entry has been removed entirely — by an operator who manually edited `sorcerer.json`, by a state-file rewrite that dropped completed/failed entries before the PR was reviewed, by a crash that killed the entry write *between* opening the PR and persisting the entry, etc. In those cases the PR sits open on GitHub but is invisible to the tick: step 12 iterates `active_wizards` and finds nothing for that PR, so the merge gate never runs.

The fix is to scan GitHub once per tick for **open bot-authored PRs on configured repos that no `active_wizards` entry claims**, and synthesize an `awaiting-review` entry so step 12 picks them up on its own terms.

**Helpers** (extracted; the tick invokes these via Bash):

- `bash $SORCERER_REPO/scripts/discover-orphan-prs.sh <bot_author> [project_root]`
  - Prints zero or more JSON lines on stdout, one per orphan PR:
    `{"repo":"<owner/name>","pr_url":"...","branch":"...","head_sha":"...","issue_key":"<SOR-N|null>"}`
  - Filters out wip/<uuid> branches and any branch/URL already claimed by an active_wizards entry.
  - Always exits 0.
- `bash $SORCERER_REPO/scripts/adopt-orphan-pr.sh <orphan_json> [project_root]`
  - Creates `.sorcerer/wizards/<wid>/` scaffold, attempts worktree materialization from the bare clone, writes `pr_urls.json`, appends a `pr-orphan-adopted` event, prints the synthesized `active_wizards` entry to stdout.
  - Worktree failure is non-fatal: the entry is written with empty `worktree_paths` and the step 12 gate falls back to GitHub-API reads.

The adopted entry carries an `orphan_adopted: true` field. Step 12's stage 6.1 (gather full review materials) MUST check this field and:
- Skip the `mcp__plugin_linear_linear__get_issue` call when `issue_linear_id` is null, and note "orphan-adopted PR — no Linear issue context" in the evidence.
- When `worktree_paths[repo]` is empty for any repo, fall back to `gh api repos/<repo>/contents/<path>?ref=<head_sha>` for cited code reads. The diff (`gh pr diff`) is still authoritative for what changed; only the post-PR full-file reads need the fallback.

**This procedure is only applicable to PRs that look like sorcerer wizard output.** Filtering on bot author + branch-pattern (excluding `wip/<uuid>` WIP-preservation branches) is the gate; operator-pushed PRs under the bot identity should not be adopted automatically. If a false adoption happens anyway, an operator can apply a `no-adopt` label to the PR and amend `discover_orphan_prs` to skip labeled PRs (not implemented in the helper above — add `--label '!no-adopt'` to the `gh pr list` filter when this becomes a real failure mode).

## Failed-wizard WIP preservation (for implement / feedback / rebase wizards)

When PR-set recovery returns nothing and the entry is about to transition to `status: failed`, the wizard's worktree may still hold uncommitted work — the SOR-381 case: an implement that finished its diff in-tree but couldn't run the workspace gates (host disk full) and reported `IMPLEMENT_FAILED` without committing. The default cleanup path destroys that diff. This procedure preserves it as a `wip/<wizard-id>` branch on GitHub before any cleanup runs, so an operator (or a future re-spawn) can recover the work or audit what the wizard actually produced.

**MUST run on every transition to `status: failed`** for `mode in {implement, feedback, rebase}` BEFORE any cleanup or `status` write. Side-effects are best-effort (a push that fails for auth/network reasons shouldn't block the failed transition), but the attempt is mandatory — a wizard whose `wip_branch` field is missing on a failed entry MUST have had this procedure attempted.

**Helper:**

- `bash $SORCERER_REPO/scripts/preserve-wizard-wip.sh <wizard_id> <issue_key> <worktree_path> <repo_slug>`
  - Mints a token for the repo owner, stages the worktree (`git add -A`), commits any pending diff with the sorcerer identity, and force-pushes to `wip/<wizard_id>` on `<repo_slug>` (e.g. `etherpilot-ai/archers`).
  - Idempotent: if there's nothing new to commit, the script no-ops the commit step and still re-pushes the existing tip.
  - Exit 0 on push success, 1 on any failure (worktree missing, token mint failure, commit failure, push failure).

**Procedure** (called from each transition-to-failed site for implement/feedback/rebase wizards):

1. For each `(repo_slug, worktree_path)` in the entry's `repos` × `worktree_paths`:
   - Call `preserve_wizard_wip <wizard_id> <issue_key> <worktree_path> <repo_slug>`.
   - On success: record `repo_slug` in a local `wip_pushed` array.
   - On failure: log `tick: wip-preserve failed for <wizard_id> on <repo_slug>; continuing` to stdout. Do NOT block the failed transition — degraded preservation is better than a hung tick.
2. Set `wip_branch: "wip/<wizard_id>"` on the entry (regardless of push success — operators looking at the entry know to check the branch).
3. Append to `.sorcerer/events.log`:
   ```json
   {"ts":"...","event":"wizard-wip-preserved","id":"<wizard-id>","issue_key":"<SOR-N>","mode":"<mode>","wip_branch":"wip/<wizard-id>","repos_pushed":["<repo_slug>",...],"repos_failed":["<repo_slug>",...]}
   ```
4. Then proceed with the existing `status: failed` write + escalation as the calling site already specifies.

This procedure is **only applicable to `mode: implement | feedback | rebase`** — architect / designer / reviewer wizards have no worktree to preserve.

## Rate-limit (429) and overload (529) handling

Every wizard spawn is a `claude -p` subprocess. When Anthropic throttles or its servers are overloaded, claude auto-retries internally; if it still can't get through, it exits non-zero. Two distinct failure modes with different recovery:

### 529 — server-side overload (transient, service-wide)

Log shape:
- `API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment.`
- `"type": "overloaded_error"`

Key property: 529 is Anthropic's backend saying "I'm busy right now." It applies equally to every provider (Max A, Max B, API keys, Bedrock, Vertex — they all hit the same upstream). Cycling providers does NOT help. The right response is a short retry after a brief cooldown.

**Detection helper**:
```bash
is_overloaded_log() {
  local log="$1"
  grep -qE "API Error: 529|\"type\":[[:space:]]*\"overloaded_error\"|529 Overloaded" "$log" 2>/dev/null
}
```

**Recovery when detected**:
1. Mark the wizard entry `status: throttled`, `retry_after: <now + 60s>`. Shorter than 429's 5-min default — 529 typically clears fast.
2. Increment a dedicated `overload_count` on the entry (initialize to 0). Do NOT increment `throttle_count` (that's for 429 strikes).
3. **Do NOT touch `providers_state`** — the provider isn't the problem, the upstream service is.
4. `overload_count >= 15` → this is an Anthropic status-page issue, not something recovery cycles will fix. For `mode in {implement, feedback, rebase}`: run **Failed-wizard WIP preservation** (above) BEFORE the status write. Then escalate with `rule: persistent-server-overload` and set the wizard `status: failed`. Point the user at https://status.claude.com in `needs_from_user`.
5. Append to events.log:
   ```json
   {"ts":"...","event":"wizard-overloaded","id":"<id>","mode":"<mode>","retry_after":"<ISO-8601>","overload_count":<N>}
   ```

### 429 — rate limit (account-specific)

Log shape:
- `You've hit your limit · resets <when>` — Max-subscription OAuth session runs out of its 5-hour bucket. No HTTP status visible, just this line.
- `API Error: Request rejected (429)` — API-key path.
- `"type": "rate_limit_error"` — structured API error.
- `rate limit` (case-insensitive) in any other error-shaped line.

Key property: 429 is account-specific. Cycling to a different provider DOES help. Mark both the wizard AND the provider throttled.

**Detection helper**:
```bash
is_rate_limited_log() {
  local log="$1"
  grep -qE "You've hit your limit|Request rejected \(429\)|\"type\":[[:space:]]*\"rate_limit_error\"|rate.limit.*exceeded" "$log" 2>/dev/null
}
```

**Classification order** in step 5 failure paths: `is_overloaded_log` first (529 can arrive with no other markers), then `is_rate_limited_log`, then the other recovery paths. They're mutually exclusive — a log doesn't typically contain both.

**Extract reset timestamp when available.** The Max-subscription variant prints a concrete reset time; parsing it gives a much better `throttled_until` than the 5-minute default. Helper:

- `bash $SORCERER_REPO/scripts/extract-reset-iso.sh <log_path>`
  - Parses the "resets <when> (<tz>)" line from a wizard log (both absolute "Apr 24, 1am (UTC)" and relative "1am (UTC)" shapes; tolerates `:30` minutes; rolls forward one day if the relative form has already passed).
  - On success: ISO-8601 UTC timestamp on stdout, exit 0.
  - On any failure (no resets line, can't parse, parsed time still in past after rollover): no output, exit 1.

Use this helper to populate **only** `providers_state[$P].throttled_until` for the provider — that's the real window during which `$P` will keep returning 429s. Fall back to `now + 300s` only when the helper exits non-zero.

**The wizard's `retry_after` is a SEPARATE concept** — see "Wizard vs provider throttles" immediately below. Do NOT set the wizard's `retry_after` from `extract_reset_iso`.

**Wizard vs provider throttles (decoupled).** A 429 means *one provider* is rate-limited, not that the wizard's work has to wait that long. With provider cycling configured, work should resume on the fallback slot as soon as the wizard is respawnable; the provider rotation is what enforces "don't try $P until its window clears", not the wizard's own clock. So:

- **Provider** `providers_state[$P].throttled_until` — the real reset window (parsed via `extract_reset_iso`, fallback `now + 300s`). Spawn-time provider selection consults this.
- **Wizard** `retry_after` — a short fixed cooldown (`now + 60s`, same as the 529 path), independent of which provider 429'd. After 60s the wizard becomes spawnable; `scripts/apply-provider-env.sh` skips the still-throttled `$P` and picks the next available slot.

If every provider is throttled, `paused_until` (set per "Global pause" below) gates the coordinator at the loop level — the wizard's 60s cooldown is harmless under pause because ticks don't run while paused.

The previous design tied the wizard's `retry_after` to the provider's reset, which made the wizard sit through `$P`'s full window even when a fallback provider was wide open. That's the bug this guidance fixes.

**Which provider ran this wizard?** Read `<state_dir>/provider` (written by `scripts/spawn-wizard.sh` at spawn time). When empty or missing, `config.json:providers` is unconfigured and there's nothing to mark throttled — only the wizard itself gets the `throttled` status.

If 429 detected:

1. Mark the entry `status: throttled`, `retry_after: <now + 60s>`. Short fixed cooldown — see "Wizard vs provider throttles (decoupled)" above. Do NOT increment `respawn_count`; throttling isn't a crash.
2. Increment a `throttle_count` field on the entry (initialize to 0).
3. **If `<state_dir>/provider` is non-empty** (let its content be `$P`): mark the provider as throttled too — set `.providers_state[$P].throttled_until = <extract_reset_iso output, fallback now + 300s>` (NOT the wizard's `retry_after` value — they're decoupled), `.providers_state[$P].throttle_count += 1`, `.providers_state[$P].last_throttled_at = now`. Append:
   ```json
   {"ts":"...","event":"provider-throttled","provider":"<P>","throttled_until":"<ISO-8601>"}
   ```
4. If `throttle_count >= 3` on the WIZARD entry: for `mode in {implement, feedback, rebase}` run **Failed-wizard WIP preservation** (above) BEFORE the status write. Then escalate with `rule: persistent-throttle`, `mode: <mode>`, `issue_key: <SOR-N or null>`, and set `status: failed`. The 3-strike rule is per-wizard, not per-provider — a provider that throttles many different wizards is working as intended (cycling kicks in). A single wizard that throttles three times across all providers suggests something deeper.
5. Append `{"ts":"...","event":"wizard-throttled","id":"<id>","mode":"<mode>","provider":"<P or null>","retry_after":"<ISO-8601>","throttle_count":<N>}` to events.log.

**Provider cycling (strict primary → fallback)**: when the tick spawns a wizard, `scripts/spawn-wizard.sh` automatically picks the first provider in `config.providers` whose `providers_state[name].throttled_until` is null or in the past. The tick itself doesn't need to choose — just rely on the spawn script. Rotation happens on the next spawn; the current wizard finishes (or throttles again) first.

**Global pause** (all-slots-exhausted): if EVERY provider in `config.providers` is currently throttled, set `sorcerer.json:paused_until` to the earliest `providers_state[*].throttled_until` (the first slot that will reopen). Append `{"ts":"...","event":"coordinator-paused","paused_until":"<ISO-8601>","reason":"all-providers-throttled"}` and `coordinator-loop.sh` sleeps until then. If `providers` is unconfigured and three wizards throttle in one tick (legacy single-slot behavior), still set `paused_until = now + 900s` with `reason: "rate-limit-storm"` — the ambient-auth case.

**Resuming**: steps 11a/b/c treat `status: throttled` identically to `status: stale`, but the trigger is `now >= retry_after` instead of heartbeat age, and respawn_count is NOT consulted or incremented. Provider-level resume is implicit: `scripts/apply-provider-env.sh` skips throttled providers on every spawn; when a slot's `throttled_until` passes, it's eligible again automatically.

## State files

**`.sorcerer/sorcerer.json`** — the persistent index:
```json
{
  "paused_until": "<ISO-8601 or null>",
  "providers_state": {
    "<provider name>": {
      "throttled_until":    "<ISO-8601 or null>",
      "throttle_count":     0,
      "last_throttled_at":  "<ISO-8601 or null>"
    }
  },
  "active_architects": [
    {
      "id": "<uuid>",
      "status": "pending-architect | running | throttled | awaiting-architect-review | architect-review-running | awaiting-tier-2 | completed | failed | archived",
      "started_at": "<ISO-8601>",
      "request_file": "<path>",
      "plan_file": "<path or null>",
      "review_wizard_id": "<reviewer's uuid or null>",
      "pid": "<int or null>",
      "respawn_count": 0,
      "retry_after": "<ISO-8601 or null>",
      "throttle_count": 0
    }
  ],
  "active_wizards": [
    {
      "id": "<uuid>",
      "mode": "design",
      "status": "running | throttled | awaiting-design-review | design-review-running | awaiting-tier-3 | completed | failed | archived",
      "started_at": "<ISO-8601>",
      "architect_id": "<parent architect uuid>",
      "sub_epic_index": 0,
      "sub_epic_name": "<string>",
      "epic_linear_id": "<id or null>",
      "manifest_file": "<path or null>",
      "review_wizard_id": "<reviewer's uuid or null>",
      "pid": "<int or null>",
      "respawn_count": 0,
      "retry_after": "<ISO-8601 or null>",
      "throttle_count": 0
    },
    {
      "id": "<uuid>",
      "mode": "architect-review | design-review",
      "status": "running | throttled | completed | failed | archived",
      "started_at": "<ISO-8601>",
      "subject_id": "<architect or designer wizard id>",
      "subject_kind": "architect | designer",
      "review_decision": "approve | reject | null",
      "review_file": "<path or null>",
      "pid": "<int or null>",
      "respawn_count": 0,
      "retry_after": "<ISO-8601 or null>",
      "throttle_count": 0
    },
    {
      "id": "<uuid>",
      "mode": "implement",
      "status": "running | throttled | awaiting-review | merging | merged | failed | blocked | archived",
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
      "refer_back_cycle": 0,
      "conflict_cycle": 0,
      "retry_after": "<ISO-8601 or null>",
      "throttle_count": 0,
      "orphan_adopted": false
    }
  ]
}

`orphan_adopted: true` is set ONLY on entries synthesized by step 11d's adoption phase from a bot-authored PR with no live wizard claim. Stage 6.1 of the merge gate keys off this field to skip the Linear fetch when `issue_linear_id` is null and to fall back to `gh api contents?ref=<sha>` reads when `worktree_paths` is empty. The flag is informational elsewhere; cleanup, archival, and refer-back paths treat the entry like any other implement wizard.
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
{"ts":"...","event":"pr-orphan-adopted","id":"<uuid>","issue_key":"<SOR-N|null>","repo":"<owner/name>","branch":"...","pr_url":"...","worktree":"<path|null>"}
{"ts":"...","event":"tick-complete"}
```

**`.sorcerer/escalations.log`** — append-only JSONL records (one per failure, `{ts, wizard_id, mode, issue_key, pr_urls, rule, attempted, needs_from_user}`).

## Tick steps

### Steps 1–3 — Already done by pre-tick

`scripts/pre-tick.sh` runs before this LLM tick and handles steps 1–3 deterministically:

- **Step 1** (reconcile state) — appends recovery entries for any `.sorcerer/architects/<id>/` with a `plan.json` that's missing from `active_architects`.
- **Step 2** (token refresh) — regenerates `.sorcerer/.token-env` if it's missing or expires within 600s; appends a `token-refreshed` event.
- **Step 3** (drain requests) — moves each `.sorcerer/requests/*.md` to a freshly-minted `.sorcerer/architects/<id>/request.md`, appends a `pending-architect` entry to `active_architects`.

When you read `.sorcerer/sorcerer.json` you ALREADY see the post-pre-tick state. Do not redo any of these — pre-tick already mutated `sorcerer.json` and `events.log`. Begin at step 4.

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
test -f .sorcerer/architects/<id>/heartbeat && hb_file=present || hb_file=absent
test -f .sorcerer/architects/<id>/plan.json && pl=present || pl=absent
# Force hb=absent when the spawn pid is gone (see "Process liveness").
if is_pid_alive "<pid>"; then hb="$hb_file"; else hb=absent; fi
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
  - Update entry: `status: awaiting-architect-review`, `plan_file: .sorcerer/architects/<id>/plan.json`. The next step (5d, below) will spawn the reviewer.
- `pl=absent, hb=absent` — possible failure:
  - If `now - started_at < 30s`, too early to judge. Skip.
  - Otherwise: **run overload detection first** (see "Rate-limit (429) and overload (529) handling" above). If `is_overloaded_log` matches, follow the 529 path (wizard throttled 60s, NO provider-state change).
  - Then **rate-limit detection**. If `is_rate_limited_log` matches, follow the 429 throttle path (wizard + provider throttled).
  - Only if neither 529 nor 429 was detected: `status: failed`. Append an escalation:
    ```bash
    bash $SORCERER_REPO/scripts/append-escalation.sh "<id>" "architect" "null" \
      "architect-no-output" \
      "Architect spawned; exited without writing plan.json." \
      "Inspect .sorcerer/architects/<id>/logs/spawn.txt for error output."
    ```
- `pl=present, hb=present` — architect mid-write or just finished writing; wait for the next tick.
- `pl=absent, hb=present` — architect still working. Heartbeat staleness handled in step 11.

#### 5b. Designer completion detection

For each `active_wizards` entry with `mode: design` and `status: running`:

```bash
test -f .sorcerer/wizards/<id>/heartbeat && hb_file=present || hb_file=absent
test -f .sorcerer/wizards/<id>/manifest.json && mf=present || mf=absent
if is_pid_alive "<pid>"; then hb="$hb_file"; else hb=absent; fi
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
  - Update entry: `status: awaiting-design-review`, `manifest_file: .sorcerer/wizards/<id>/manifest.json`, `epic_linear_id: <id>`. The next step (5e, below) will spawn the reviewer.
- `mf=absent, hb=absent`:
  - If `now - started_at < 30s`, too early to judge. Skip.
  - Otherwise: **run overload detection first** (see "Rate-limit (429) and overload (529) handling" above). If `is_overloaded_log` matches, follow the 529 path (wizard throttled 60s, NO provider-state change).
  - Then **rate-limit detection**. If `is_rate_limited_log` matches, follow the 429 throttle path (wizard + provider throttled).
  - Only if neither 529 nor 429 was detected: `status: failed`. Append an escalation:
    ```bash
    bash $SORCERER_REPO/scripts/append-escalation.sh "<id>" "design" "null" \
      "designer-no-output" \
      "Designer spawned; exited without writing manifest.json." \
      "Inspect .sorcerer/wizards/<id>/logs/spawn.txt for error output."
    ```
- `mf=present, hb=present` — designer just finished writing; wait for next tick.
- `mf=absent, hb=present` — designer still working. Step 11 handles staleness.

#### 5c. Implement / feedback completion detection

For each `active_wizards` entry with `mode: implement` (covers both initial implement and any subsequent feedback cycles — the mode stays implement; feedback is a spawn phase) and `status: running`:

```bash
test -f <state_dir>/heartbeat && hb_file=present || hb_file=absent
test -f <state_dir>/pr_urls.json && pr=present || pr=absent
if is_pid_alive "<pid>"; then hb="$hb_file"; else hb=absent; fi
# Determine which spawn is running by reading the most recent log file's last line.
# Logs: logs/spawn.txt for initial implement; logs/feedback-<N>.txt for feedback cycle N;
# logs/rebase-<N>.txt for rebase cycle N.
latest_log=$(ls -t <state_dir>/logs/*.txt 2>/dev/null | head -1)
last_line=$(tail -1 "$latest_log" 2>/dev/null)
```

Cases:
- `hb=absent` AND `pr=present` AND `last_line` starts with `IMPLEMENT_OK` or `FEEDBACK_OK`:
  - **Implement/feedback completed successfully.**
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
- `hb=absent` AND `last_line` starts with `REBASE_OK`:
  - **Rebase completed successfully.** No pr_urls.json changes (rebase doesn't write it — same PRs, same URLs).
  - Print to **stdout**: `Rebase <wizard-id> completed (<issue_key>, cycle <N>). Re-queueing for review.`
  - Append event:
    ```json
    {"ts":"...","event":"rebase-completed","id":"<id>","issue_key":"<SOR-N>","cycle":<N>}
    ```
  - Update entry: `status: awaiting-review` (step 12 will re-evaluate the PR set next tick). Leave `pr_urls` as-is.
- `hb=absent` AND `last_line` starts with `IMPLEMENT_FAILED`, `FEEDBACK_FAILED`, or `REBASE_FAILED`:
  - Wizard reported its own failure. Run **Failed-wizard WIP preservation** (above) BEFORE the status write — the wizard's worktree may hold uncommitted work (the canonical SOR-381 case: `IMPLEMENT_FAILED: host disk full`, real diff in-tree, never committed). Then update `status: failed`. Append to `.sorcerer/escalations.log` with `rule: <implement|feedback|rebase>-self-reported-failure`, include the wizard's failure reason and the `wip_branch` value.
- `hb=absent` AND `pr=absent` AND no completion marker in log:
  - If `now - started_at < 30s`, too early — skip.
  - Otherwise: **run overload detection first** (see "Rate-limit (429) and overload (529) handling" above). If `is_overloaded_log` matches, follow the 529 path (wizard throttled 60s, NO provider-state change).
  - Then **rate-limit detection**. If `is_rate_limited_log` matches, follow the 429 throttle path (wizard + provider throttled).
  - Next: **run the PR-set recovery check** (see "PR-set recovery" above). Call `discover_pr_set <branch_name> <repos…>`. If it returns a complete pr_urls map, the wizard completed durably even though it didn't write `pr_urls.json` — write it now, set `status: awaiting-review`, set the entry's `pr_urls` to the discovered map, append a `pr-set-recovered` event with `source: "step5c"`. Do NOT mark failed, do NOT escalate. The next tick's step 12 will evaluate the set normally.
  - Only if neither 529 nor 429 was detected AND recovery found no PR set: crashed without writing output. Run **Failed-wizard WIP preservation** (above) BEFORE the status write. Then `status: failed`. Append to `.sorcerer/escalations.log` with `rule: implement-no-output` (or `feedback-no-output`, `rebase-no-output`) and the `wip_branch` value.
- `pr=present, hb=present` — wizard mid-write; wait for next tick.
- `hb=present` — wizard still working; step 11c handles staleness.

#### 5d. Architect-review spawn + completion

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
  - Run the 429 check (see "Rate-limit (429) handling"). If 429 detected, take the throttle path on the reviewer entry (do NOT touch the parent architect's status — it stays at `architect-review-running`).
  - Else if `now - started_at < 30s`, too early — skip.
  - Else: crashed without output. Reviewer `status: failed`, parent architect `status: failed`. Escalate with `rule: architect-review-no-output`.
- `rv=present, hb=present` — reviewer mid-write; wait next tick.
- `hb=present` — still working; step 11 handles staleness (treat reviewer wizards under the same 5-min heartbeat rule as designer wizards in step 11b).

#### 5e. Design-review spawn + completion

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

5. Once ALL sub-epics for an architect have been evaluated, transition the architect's `status` from `awaiting-tier-2` to `completed` ONLY if every sub-epic **named in `plan.json`** has a matching `active_wizards` designer entry in status `completed` or `archived`. Specifically: iterate `plan.json:sub_epics[].name`, and for each name verify there exists an entry with `mode == "design"`, `architect_id == <this-architect>`, `sub_epic_name == <name>`, AND status in `{completed, archived}`. If ANY sub-epic name lacks such an entry — including sub-epics that haven't had a designer spawned yet because their cross-epic deps were still pending on the previous tick — leave the architect at `awaiting-tier-2`. This keeps the architect in scope of step 6 so a newly-dep-satisfied sub-epic gets its designer spawned on a future tick. The naive rule "every existing designer is completed" is NOT sufficient; it silently succeeds when some sub-epics haven't spawned yet. Leaving the architect at `awaiting-tier-2` also means `has_in_flight_work` stays true while downstream work is still pending.

### Step 7 — Standalone-issue sweeper (orphaned-Linear-issue catcher)

**Cadence:** run only when `tick_count % 30 == 0` (skip with stdout `tick: step-7-sweep skipped (next at tick N)` otherwise). Sorcerer doesn't track tick_count durably; derive from `events.log` line count modulo 30, or from a local counter on the in-memory tick state. Quiet on the happy path.

**Purpose.** Cluster-4-of-the-audit fix. The 2026-04-26 SOR-407/408/409/410 case: four Urgent issues filed standalone in Linear without an architect chain → invisible to the dispatch pool until an operator manually submitted a sorcerer request. This sweeper auto-catches that shape.

**Procedure (run only at the cadence above):**

1. List all SOR issues in `state:Backlog` OR `state:"In Progress"` with `priority IN (1, 2)` (Urgent, High) via `mcp__plugin_linear_linear__list_issues` (team=SOR, limit=250). If the Linear MCP is needs-auth, log `tick: step-7-sweep skipped — Linear MCP needs-auth` and return.
2. Build the set of `linear_id` values that appear in any active manifest: scan `.sorcerer/wizards/*/manifest.json` for `issues[*].linear_id`. Also include `linear_id`s of any active architect's plan whose sub-epics' mandates cite the issue (since the architect's plan is upstream of the manifest).
3. For each Urgent/High Linear issue NOT in the active set: this is an orphaned issue.
4. If the orphaned-set is non-empty, emit ONE consolidated event:
   ```json
   {"ts":"...","event":"orphan-issues-detected","priority_high_or_urgent":N,"issue_keys":["SOR-X","SOR-Y",...]}
   ```
5. Auto-file a sorcerer request to incorporate the orphans into a fresh architect run, BUT only when:
   - The orphan set is **stable across two consecutive sweeps** (recorded via a marker file `.sorcerer/orphan-sweep-prev.json` containing the prior sweep's `issue_keys` array). This avoids racing the operator who's mid-flight filing related issues.
   - The orphan set has at least one Urgent (priority=1) issue.
   - No active architect is currently processing the same `issue_keys` (re-scan plans).

   When all three hold, write a request file under `.sorcerer/requests/<ts>-orphan-issues-<keys-joined>.md` with body:
   ```
   Auto-generated by step-7 standalone-issue sweeper on <ts>.

   The following Urgent / High Linear issues are not part of any active architect plan or designer manifest. They've been orphaned for at least two sweep cycles (~60 ticks). Decompose them into a single architect run with appropriate sub-epic boundaries:

   - SOR-NNN — <title> — priority <Urgent|High>
   - SOR-MMM — ...
   ```
   Step 3 will pick this up on the same tick and route to a new architect.
6. Update `.sorcerer/orphan-sweep-prev.json` with the current sweep's `issue_keys` for next-cycle comparison.

**Quiet on the happy path.** No events / requests when the orphan set is empty or hasn't been stable for 2 cycles.

### Step 8 — Decide implement actions

For each `active_wizards` entry with `mode: design` and `status: awaiting-tier-3`:

1. Read its `manifest_file` (`.sorcerer/wizards/<designer-id>/manifest.json`). Parse `issues` (list of `{linear_id, issue_key, repos, merge_order?, depends_on?}`).
2. For each issue, check if there's already an `active_wizards` entry with `mode: implement` and `issue_linear_id` matching this issue. If yes, skip (already scheduled or running or done).
3. **Dependency check (Linear ground truth, slice 61).** If the issue has a non-empty `depends_on` list, verify every dependency is **`statusType: completed` (Done) or `canceled` (won't happen) in Linear** before scheduling. Linear is the source of truth — sorcerer's internal `active_wizards` lookup was unreliable (a dep that lived in another designer's manifest but had no implement entry yet looked "found but unstatused" to the LLM, which interpreted it as satisfied — the 2026-04-27 SOR-395/396 re-spawn-and-re-fail loop, where SOR-441 was planned-but-not-yet-implemented and the wizards spawned anyway).

   For each `dep` in `depends_on`:
   - Call `mcp__plugin_linear_linear__get_issue` with `id=<dep>`. Cache the result within this tick — the same `dep` may appear across multiple candidates' `depends_on` lists; one call covers it.
   - If the call errors or returns nothing: treat the dep as **unsatisfied** (do not assume satisfied on missing data). Log `tick: deferring <issue_key> — dep <dep> Linear lookup failed`.
   - Examine `statusType`:
     - `completed` → satisfied (the dep's implement merged and Linear was flipped to Done; either by the wizard's step-13 push or slice 49's reconciliation sweep).
     - `canceled` → satisfied (the dep won't happen; don't block on it forever).
     - `backlog`, `unstarted`, `started`, `triage` → **unsatisfied**. Skip this issue (defer to next tick). Log: `tick: deferring <issue_key> — dep <dep> still <statusType>`.
   - Only candidates with ALL deps in `completed` or `canceled` state proceed to the candidate list.

   **Linear MCP unavailable fallback.** If any `get_issue` call returns the needs-auth error (and the Linear MCP isn't reachable this tick), fall back to the older active_wizards/manifest-based check for THIS tick only:
   - Find the dep in `active_wizards` (by `issue_linear_id` or `issue_key`); if status ∈ {merged, done, archived} → satisfied.
   - If not found in active_wizards but found in some manifest → **unsatisfied** (planned but not yet active; the prior bug treated this as satisfied). Skip.
   - If not found anywhere → **unsatisfied** (outside sorcerer's tracking). Skip.
   Log `tick: dep-check fell back to active_wizards lookup — Linear MCP needs-auth` once per tick.

   The Linear-ground-truth path is mandatory when the MCP is healthy. Do NOT skip the get_issue calls "for cost" — they're the same calls the priority sort already makes (cached in the same per-tick cache), and they're the only way to keep dep-checking correct as wizards transition through running → merging → merged → archived.
4. Otherwise (no deps, or all deps satisfied), the issue is a candidate to spawn implementing.

Collect the candidate list across all designers.

**Priority sort.** Before steps 9 and 10 apply the concurrency cap, sort candidates ascending by Linear `priority` so the limited spawn slots go to the most important work. For each unique `linear_id` in the candidate list, call `mcp__plugin_linear_linear__get_issue` with `id=<linear_id>` and read both `priority.value` (Linear: `1`=Urgent, `2`=High, `3`=Medium, `4`=Low, `0`=None) and `createdAt` (ISO-8601 timestamp). Cache results within this tick — the same `linear_id` should not be fetched twice.

Sort key per candidate:

1. **Normalized priority** (ascending). Map `0` → `5` so unprioritized issues sort last; otherwise pass through. Result: Urgent (1) → High (2) → Medium (3) → Low (4) → None (5).
2. **Linear `createdAt`** (ascending — oldest first) as the tie-break for equal-priority candidates. Older issues have been waiting longer; within a priority band, draining the queue from the oldest end matches operator intuition. Manifest order is NOT a tie-break — a newer designer's manifest writes newer Linear issues first, which would otherwise let recently-filed work jump the queue ahead of older same-priority work that's been waiting across many ticks.

If the Linear MCP is in needs-auth state on this tick (any `get_issue` call returns a needs-auth error), fall back to the un-sorted (manifest-order) candidate list and log `tick: priority-sort skipped — Linear MCP needs-auth`. Do NOT escalate — degrading to FIFO is acceptable; the next tick will re-sort once auth is restored. The sort is best-effort and never blocks dispatch.

Note that this affects only **which candidate gets the next spawn slot** — already-running implements are not preempted, and `depends_on` constraints from step 8.3 are still honored (they were already filtered out of the candidate list above).

Then in steps 9 and 10, process candidates subject to the concurrency cap.

### Step 9 — Worktree prep for implement candidates

Read `config.json:limits.max_concurrent_wizards` (default 3). Count running entries. For each implement candidate from step 8, while running-count is below the cap:

**Pre-flight resource gate (run once at the top of step 9, before iterating candidates).** Spawning an implement wizard allocates a worktree (typically 100MB-300MB depending on repo) and the wizard's `cargo` (or equivalent) build can grow `target/` to 10-20GB. Disk exhaustion is the canonical SOR-381 failure mode — a wizard reports `IMPLEMENT_FAILED` because workspace gates can't write to disk, and now slice 55 has to WIP-preserve work that should never have been spawned in the first place. Pre-flight refuses to spawn when host resources are below floor. The gate is **disk + provider** today; memory-floor is structurally similar but harder to threshold meaningfully (cargo's RSS varies wildly by crate) and is left for a follow-up.

1. **Disk floor.** Read `config.json:limits.disk_floor_gb` (default `40`). Run `df -BG --output=avail "$PROJECT_ROOT" | tail -1 | tr -dc '0-9'` to get available GB. If `< disk_floor_gb`: do NOT spawn any candidates this tick. Append ONE escalation per tick (suppress duplicates by checking the most recent `escalations.log` line for `rule: spawn-deferred-disk-floor` from this tick):
   ```bash
   jq -nc \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg rule "spawn-deferred-disk-floor" \
     --argjson avail_gb <N> \
     --argjson floor_gb <FLOOR> \
     --argjson candidates_deferred <COUNT> \
     --arg attempted "Implement spawn deferred this tick: host has <N>G free, below floor <FLOOR>G. <COUNT> candidates queued." \
     --arg needs_from_user "Free disk (target/ caches, model weights, archived bare clones) or lower limits.disk_floor_gb in config.json. Coordinator will retry on the next tick once free space is above floor." \
     '{ts:$ts, wizard_id:null, mode:"coordinator", issue_key:null, pr_urls:null, rule:$rule, attempted:$attempted, needs_from_user:$needs_from_user, avail_gb:$avail_gb, floor_gb:$floor_gb, candidates_deferred:$candidates_deferred}' \
     >> .sorcerer/escalations.log
   ```
   Emit `tick: spawn deferred — disk <N>G < floor <FLOOR>G` to stdout and skip step 10 entirely. **Step 11 (heartbeat poll) and step 13 (cleanup) MUST still run** — running ticks free disk via merged-wizard cleanup, so blocking them would be self-defeating.

2. **Provider floor.** Sample `apply-provider-env.sh` indirectly: read `config.json:providers[].name` and `sorcerer.json:providers_state[<name>].throttled_until`. Count providers whose `throttled_until` is null/missing/in-the-past. If `0`: do NOT spawn any candidates this tick. Suppress duplicate escalations as above; emit `tick: spawn deferred — all providers throttled` and skip step 10.

3. **Concurrency floor (existing).** If `running_count >= max_concurrent_wizards`: skip step 10 entirely; current implements drain naturally before next spawn.

If all three floors pass, proceed to per-candidate processing below.

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
       <default-branch-from-config-or-fetched-from-gh>
     ```
     Note: use the **local** branch ref (e.g. `main`), NOT `origin/main`. In a bare clone the default refspec `+refs/heads/*:refs/heads/*` updates `refs/heads/*` on every fetch but leaves `refs/remotes/origin/*` frozen at clone time. `origin/main` is therefore stale; the canonical tip lives at `refs/heads/main`. `ensure-bare-clones.sh` is responsible for fetching before this step so the local ref is fresh.
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

After processing all candidates for a designer, transition the designer's `status` from `awaiting-tier-3` to `completed` ONLY if every issue in its `manifest.json` has an implement wizard in status `merged` or `archived` — i.e. the work has actually landed, not merely been dispatched. A designer whose manifest has any issue in `running`, `throttled`, `awaiting-review`, `merging`, `failed`, or `blocked` state stays at `awaiting-tier-3`. That keeps the manifest in scope: if the operator strips a `failed` implement wizard to retry it, the next tick's step 8 sees the designer at `awaiting-tier-3`, no active implement entry for that issue, and re-schedules. The alternative rule ("complete on dispatch") fires the designer to `completed` prematurely, and a subsequently-stripped or failed implement slips through the coordinator's tick without being reconsidered.

### Step 11 — Heartbeat poll and throttle resume

#### 11.0. Throttled resume (run first)

For every entry in `active_architects + active_wizards` with `status: throttled`:
- If `now < retry_after`: skip (still cooling down).
- If `now >= retry_after`: respawn the wizard with its original spawn command (same command the initial spawn used; architect → `spawn-wizard.sh architect --request-file ...`, designer → `spawn-wizard.sh design --architect-plan-file ... --sub-epic-index ...`, implement/feedback/rebase → `spawn-wizard.sh <mode> --issue-meta-file <state_dir>/meta.json`). Do NOT increment `respawn_count`. Set `status: running`, clear `retry_after`, update `pid` and `started_at`. Append:
  ```json
  {"ts":"...","event":"wizard-resumed","id":"<id>","mode":"<mode>","throttle_count":<N>}
  ```

Also check the top-level `paused_until`: if set and now >= paused_until, clear it and append `{"ts":"...","event":"coordinator-resumed"}`.

#### 11a. Architects

For each `active_architects` entry with `status: running`:

**Max-age check (run first).** See "Max wall-clock age" above. Apply with `<mode>="architect"`. If the age exceeds the cap: SIGTERM the pid, mark `status: failed`, append `wizard-killed-max-age` event + an escalation with `rule: wizard-max-age-exceeded`. Skip the rest of 11a for this entry.

```bash
mtime=$(stat -c %Y .sorcerer/architects/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty (file missing): step 5a already classified it; skip here.
- If `now - mtime > 300` (5 minutes): heartbeat is stale. **Consult pid liveness (`is_pid_alive`) before deciding**:
  - **Pid is ALIVE** — the architect is still running but hasn't touched heartbeat recently. This is usually a long repo survey or a long MCP call, not a stuck process. Do NOT respawn and do NOT touch `respawn_count`. Log `tick: architect <id> heartbeat stale <age>s but pid alive; trusting busy wizard (max-age enforces the eventual cap)` and move on. Slice-37's max-age gate bounds the wait at the configured wall-clock ceiling.
  - **Pid is DEAD** — heartbeat stale AND process gone is a real crash. Follow the respawn-or-fail ladder:
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

**Max-age check (run first).** See "Max wall-clock age" above. Apply with `<mode>="design"`. If over cap: kill + fail + escalate. Skip the rest.

```bash
mtime=$(stat -c %Y .sorcerer/wizards/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty (file missing): step 5b already classified it; skip here.
- If `now - mtime > 300` (5 minutes): heartbeat is stale. **Consult pid liveness (`is_pid_alive`) before deciding**:
  - **Pid is ALIVE** — designer is still running (long explorable-repo survey or long Linear MCP sequence is common here). Do NOT respawn, do NOT touch `respawn_count`. Log `tick: designer <id> heartbeat stale <age>s but pid alive; trusting busy wizard`. Max-age bounds the wait.
  - **Pid is DEAD** — stale AND gone:
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

#### 11b-r. Review wizards (architect-review, design-review)

For each `active_wizards` entry with `mode: architect-review` or `mode: design-review` and `status: running`:

**Max-age check (run first).** Apply with `<mode>` = the entry's actual mode (`architect-review` or `design-review`). Kill + fail + escalate if over cap. On fail, also mark the parent (architect or designer — follow `subject_id`) `status: failed` since they're blocked without a reviewer verdict. Skip the rest of 11b-r for this entry.

```bash
mtime=$(stat -c %Y .sorcerer/wizards/<id>/heartbeat 2>/dev/null)
```

- If `mtime` is empty: step 5d / 5e handles it. Skip.
- If `now - mtime > 300` (5 minutes): heartbeat is stale. **Consult pid liveness (`is_pid_alive`) before deciding**:
  - **Pid is ALIVE** — reviewer is still running (fetching Linear issues + reading manifests can take minutes on a large epic). Do NOT respawn, do NOT touch `respawn_count`. Log `tick: <mode> <id> heartbeat stale <age>s but pid alive; trusting busy reviewer`. Max-age bounds the wait.
  - **Pid is DEAD** — stale AND gone:
    - `respawn_count == 0`: increment, re-spawn with the same flags the original spawn used. Capture new pid. Append `<mode>-stale-respawn` event.
    - `respawn_count >= 1`: `status: failed`, AND mark the parent (architect or designer) `status: failed`. Append to `.sorcerer/escalations.log` with `rule: stale-heartbeat-second-failure`, `mode: <architect-review|design-review>`. Clear the parent's `review_wizard_id`.

#### 11c. Implement wizards

For each `active_wizards` entry with `mode: implement` and `status: running`:

**Max-age check (run first).** Apply with `<mode>` = whatever spawn phase the entry is currently in — for an initial implement spawn, `implement`; for a feedback-cycle respawn (see step 12.6b), `feedback`; for a rebase respawn (see step 12.6c), `rebase`. Derive the current phase by inspecting the latest log file's name (`spawn.txt` → implement; `feedback-<N>.txt` → feedback; `rebase-<N>.txt` → rebase). If over cap: run the PR-set recovery check first (a max-age wizard may still have durable PRs on GitHub — recover them rather than lose the work). If PRs exist, route to `awaiting-review`. Else kill + fail + escalate. Skip the rest.

```bash
mtime=$(stat -c %Y <state_dir>/heartbeat 2>/dev/null)
```

- If `mtime` is empty: step 5c handles it. Skip.
- If `now - mtime > 300`: heartbeat is stale. **Consult pid liveness (`is_pid_alive`) before deciding**:
  - **Pid is ALIVE** — the implement wizard is still running. Cargo builds, test suites, Sylvan FFI compilations, and long Phase-2 repo exploration can all occupy the claude subprocess for >5 min without heartbeat touches. Do NOT respawn, do NOT touch `respawn_count`, do NOT kill. Log `tick: implement <id>/<issue_key> heartbeat stale <age>s but pid alive; trusting busy wizard`. Slice-37's max-age gate bounds the wait at the configured wall-clock ceiling.
  - **Pid is DEAD** — stale AND gone, a real crash:
    - **PR-set recovery check (run before respawn).** Call `discover_pr_set <branch_name> <repos…>` (see "PR-set recovery" above). If it returns a complete pr_urls map, the wizard effectively finished its work — the stale heartbeat just means it died during cleanup. Write `pr_urls.json`, set `status: awaiting-review`, set the entry's `pr_urls` to the discovered map, append `pr-set-recovered` with `source: "step11c"`. Do NOT respawn, do NOT increment `respawn_count`.
    - Only if recovery found no PR set: proceed with the respawn-or-fail path below.
    - `respawn_count == 0`: increment, re-spawn:
      ```bash
      nohup bash scripts/spawn-wizard.sh implement \
        --wizard-id <id> \
        --issue-meta-file <state_dir>/meta.json \
        > <state_dir>/logs/spawn.txt 2>&1 &
      echo $!
      ```
      Capture new pid. Append `implement-stale-respawn` event.
    - `respawn_count >= 1`: run **Failed-wizard WIP preservation** (above) BEFORE the status write. Then `status: failed`. Append to `.sorcerer/escalations.log` with `rule: stale-heartbeat-second-failure`, `mode: implement`, `issue_key: <SOR-N>`, and the `wip_branch` value.

### Step 11d — Orphan-PR adoption

Before step 12 runs the merge gate, scan GitHub for **bot-authored PRs on configured repos that no `active_wizards` entry claims**, and synthesize `awaiting-review` entries for them. See "Orphan-PR adoption" above for the failure mode and the helpers; this step wires them into the tick.

1. Determine the bot author. Read the App identity from the gh authentication context — `gh api user --jq .login` returns the bot user (e.g. `sorcerer-b3k[bot]`). On installations where the App login isn't directly resolvable, fall back to the literal `app/<App-slug>` form documented in `config.json` under `github.bot_login` (add the field if absent; doctor.sh should warn when it can't be derived).

2. Run `discover_orphan_prs "<bot-author>"`. If the output is empty, skip the rest of this step.

3. For each line of output (one orphan PR per line):
   - Call `adopt_orphan_pr "<orphan_json>"`. Capture the synthesized entry from stdout.
   - Append the entry to `.active_wizards` in `sorcerer.json`. Use `jq` with input piping to avoid clobbering concurrent writes:
     ```bash
     tmpf=$(mktemp)
     jq --argjson entry "$new_entry" '.active_wizards += [$entry]' .sorcerer/sorcerer.json > "$tmpf"
     mv "$tmpf" .sorcerer/sorcerer.json
     ```
   - Log into the coordinator log: `tick: adopted orphan PR <pr_url> as wizard <wid> (issue <SOR-N or "?">, branch <branch>)`.

4. **Cap the per-tick adoption count at 5.** If `discover_orphan_prs` returns more than 5, adopt the first 5 (sorted by repo then branch for determinism), log `tick: deferred N orphan-PR adoptions to next tick (per-tick cap)`, and let subsequent ticks pick up the rest. The cap protects against an accidental flood (e.g. someone authors 50 PRs under the bot identity by mistake) and gives the merge gate room to process adopted entries before the next batch lands.

5. **Rate the worktree-materialization step.** If `git worktree add` fails for an orphan, the entry is still added with empty `worktree_paths` — step 12 must fall back to GitHub-API reads, per the contract documented in "Orphan-PR adoption" above. Do NOT block adoption on a worktree failure; an orphan PR with no worktree is still better than an orphan PR the gate ignores.

6. Adopted entries flow into step 12 normally on the *same* tick — once `.active_wizards` has been updated, step 12's `for each active_wizards entry with mode: implement and status: awaiting-review` loop will see them. There's no need to defer adoption to the next tick.

The `orphan_adopted: true` flag on synthesized entries is informational only at this layer; step 12's stage 6.1 reads it to decide on the Linear-fetch skip and worktree-fallback paths.

### Step 12 — PR-set review and merge

**Lazy-loaded.** If at least one `active_wizards` entry has `mode: implement` and `status: awaiting-review`, Read `$SORCERER_REPO/prompts/tick-step-12-pr-review.md` and follow it. Otherwise emit `step 12: skipped — no awaiting-review entries` and proceed to step 13. The body covers PR fetching, the merge-readiness gate, CI/bot/LLM gates, refer-back/rebase routing, and the second-opinion review for the merge path; do NOT skip any of those when an awaiting-review entry exists.

(The step body lives in a separate file because it is the largest step in the tick and most ticks have no awaiting-review work — paying for those ~30 KB of prompt every tick is wasted budget when the gate isn't firing.)


### Steps 13-14 — Already done by post-tick

`scripts/post-tick.sh` runs AFTER this LLM tick (only on tick success, not on 429/529 paths) and handles cleanup + archival deterministically:

- **Step 13** (cleanup merged issues) — for each `mode: implement` / `status: merging` wizard, polls each PR's state via `gh pr view`, runs `git worktree remove` + `git branch -d` cleanup when all are MERGED, pushes Linear → Done via `scripts/linear-set-state.sh` (Haiku-backed MCP write), transitions to `merged` on Linear success or `blocked` on timeout/partial. Also runs the 7-day reconciliation sweep that calls `scripts/linear-get-state.sh` and re-pushes Done if Linear has drifted.
- **Step 14** (archive completed wizards) — entries past 7-day retention transition to `status: archived` with `archived_at` and have their on-disk state dirs removed.

Do NOT do any of this in the LLM tick. The mutations happen between this tick's end and the next tick's pre-tick. Steps 13 and 14 are skipped from your responsibilities; proceed directly from step 12 to step 15 (persist state).
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
