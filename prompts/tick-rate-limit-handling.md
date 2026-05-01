# Rate-limit (429) and overload (529) handling

Every wizard spawn is a `claude -p` subprocess. When Anthropic throttles or its servers are overloaded, claude auto-retries internally; if it still can't get through, it exits non-zero. Two distinct failure modes with different recovery:

## 529 — server-side overload (transient, service-wide)

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
4. `overload_count >= 15` → this is an Anthropic status-page issue, not something recovery cycles will fix. For `mode in {implement, feedback, rebase}`: run **Failed-wizard WIP preservation** (see `prompts/tick-failed-wizard-wip.md`) BEFORE the status write. Then escalate with `rule: persistent-server-overload` and set the wizard `status: failed`. Point the user at https://status.claude.com in `needs_from_user`.
5. Append to events.log:
   ```json
   {"ts":"...","event":"wizard-overloaded","id":"<id>","mode":"<mode>","retry_after":"<ISO-8601>","overload_count":<N>}
   ```

## 429 — rate limit (account-specific)

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

**The wizard's `retry_after` is a SEPARATE concept** — see "Wizard vs provider throttles" immediately below. Do NOT set the wizard's `retry_after` from `extract-reset-iso.sh`'s output.

**Wizard vs provider throttles (decoupled).** A 429 means *one provider* is rate-limited, not that the wizard's work has to wait that long. With provider cycling configured, work should resume on the fallback slot as soon as the wizard is respawnable; the provider rotation is what enforces "don't try $P until its window clears", not the wizard's own clock. So:

- **Provider** `providers_state[$P].throttled_until` — the real reset window (parsed via `scripts/extract-reset-iso.sh`, fallback `now + 300s`). Spawn-time provider selection consults this.
- **Wizard** `retry_after` — a short fixed cooldown (`now + 60s`, same as the 529 path), independent of which provider 429'd. After 60s the wizard becomes spawnable; `scripts/apply-provider-env.sh` skips the still-throttled `$P` and picks the next available slot.

If every provider is throttled, `paused_until` (set per "Global pause" below) gates the coordinator at the loop level — the wizard's 60s cooldown is harmless under pause because ticks don't run while paused.

The previous design tied the wizard's `retry_after` to the provider's reset, which made the wizard sit through `$P`'s full window even when a fallback provider was wide open. That's the bug this guidance fixes.

**Which provider ran this wizard?** Read `<state_dir>/provider` (written by `scripts/spawn-wizard.sh` at spawn time). When empty or missing, `config.json:providers` is unconfigured and there's nothing to mark throttled — only the wizard itself gets the `throttled` status.

If 429 detected:

1. Mark the entry `status: throttled`, `retry_after: <now + 60s>`. Short fixed cooldown — see "Wizard vs provider throttles (decoupled)" above. Do NOT increment `respawn_count`; throttling isn't a crash.
2. Increment a `throttle_count` field on the entry (initialize to 0).
3. **If `<state_dir>/provider` is non-empty** (let its content be `$P`): mark the provider as throttled too — set `.providers_state[$P].throttled_until` to the output of `bash "$SORCERER_REPO/scripts/extract-reset-iso.sh" "<state_dir>/logs/<latest-log>"` (or fall back to `now + 300s` if the script exits non-zero); NOT the wizard's `retry_after` value (they're decoupled). Also `.providers_state[$P].throttle_count += 1`, `.providers_state[$P].last_throttled_at = now`. Append:
   ```json
   {"ts":"...","event":"provider-throttled","provider":"<P>","throttled_until":"<ISO-8601>"}
   ```
4. If `throttle_count >= 3` on the WIZARD entry: for `mode in {implement, feedback, rebase}` run **Failed-wizard WIP preservation** (see `prompts/tick-failed-wizard-wip.md`) BEFORE the status write. Then escalate with `rule: persistent-throttle`, `mode: <mode>`, `issue_key: <SOR-N or null>`, and set `status: failed`. The 3-strike rule is per-wizard, not per-provider — a provider that throttles many different wizards is working as intended (cycling kicks in). A single wizard that throttles three times across all providers suggests something deeper.
5. Append `{"ts":"...","event":"wizard-throttled","id":"<id>","mode":"<mode>","provider":"<P or null>","retry_after":"<ISO-8601>","throttle_count":<N>}` to events.log.

**Provider cycling (strict primary → fallback)**: when the tick spawns a wizard, `scripts/spawn-wizard.sh` automatically picks the first provider in `config.providers` whose `providers_state[name].throttled_until` is null or in the past. The tick itself doesn't need to choose — just rely on the spawn script. Rotation happens on the next spawn; the current wizard finishes (or throttles again) first.

**Global pause** (all-slots-exhausted): if EVERY provider in `config.providers` is currently throttled, set `sorcerer.json:paused_until` to the earliest `providers_state[*].throttled_until` (the first slot that will reopen). Append `{"ts":"...","event":"coordinator-paused","paused_until":"<ISO-8601>","reason":"all-providers-throttled"}` and `coordinator-loop.sh` sleeps until then. If `providers` is unconfigured (ambient-auth single-slot mode) and three wizards throttle in one tick, set `paused_until = now + 900s` with `reason: "rate-limit-storm"`.

**Resuming**: steps 11a/b/c treat `status: throttled` identically to `status: stale`, but the trigger is `now >= retry_after` instead of heartbeat age, and respawn_count is NOT consulted or incremented. Provider-level resume is implicit: `scripts/apply-provider-env.sh` skips throttled providers on every spawn; when a slot's `throttled_until` passes, it's eligible again automatically.
