# Tick step 12 — PR-set review and merge

This file is loaded on demand by the coordinator tick. Read it when at least one `active_wizards` entry has `mode: implement` and `status: awaiting-review`.

---

For each `active_wizards` entry with `mode: implement` and `status: awaiting-review`:

1. **Fetch the PR set.** For each `<repo, pr_url>` in `pr_urls`:
   ```bash
   gh pr view "<pr_url>" --json state,mergeable,mergeStateStatus,statusCheckRollup,reviews,comments,files,body,additions,deletions
   ```

2. **Defer if any PR is not yet ready for review.** A PR is "ready" when ALL of the following are true:
   - `state == "OPEN"` (not draft, not already merged/closed)
   - `statusCheckRollup` is **non-empty** AND every check in it has a **terminal conclusion** — one of `SUCCESS | FAILURE | ERROR | CANCELLED | SKIPPED | NEUTRAL | TIMED_OUT | ACTION_REQUIRED | STALE`. Non-terminal states that force a defer: `PENDING | QUEUED | IN_PROGRESS | WAITING`.

   **Empty `statusCheckRollup`** is NOT a green light. It means either:
   - CI just hasn't started yet (race: PR opened seconds ago, checks haven't queued). → Defer this tick; next tick will see them.
   - The target repo has no CI at all. → Suspicious. After 10 min of an empty rollup, escalate with `rule: no-ci-checks-found` (the user needs to decide: is this repo actually no-CI and safe to merge blind, or is the App missing the Checks permission, or is CI broken?). DO NOT merge blindly in either case.

   Use `gh pr checks <pr_url>` in addition to the JSON view — it prints human-readable state per check and is the easier signal for "anything unfinished?".

   If any PR is draft or has non-terminal checks: skip this wizard for this tick. Log `tick: deferring review of <issue_key> — PR(s) not ready (<reason>)`.

3. **Merge-readiness gate (pre-empts the other gates when it fails).** If ANY PR in the set has `mergeable == "CONFLICTING"` or `mergeStateStatus` in `["BEHIND", "DIRTY"]`:
   - This is a rebase situation, not a review situation. Proceed to step 6c (rebase path) — do NOT run CI/bot/LLM gates against a branch that's behind main, it'll just produce noise.
   - Exception: if the wizard's `conflict_cycle >= max_refer_back_cycles` (reusing the same cap), skip the rebase path and escalate with `rule: conflict-cap-reached`. The default cap is 8 rebase attempts.

4. **CI gate.** Every check in every PR's `statusCheckRollup` must have `conclusion == "SUCCESS"` (or `SKIPPED` for checks the repo considers optional — treat `SKIPPED` as passing). If ANY check has `conclusion` in `["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STALE"]`: **route to refer-back (step 6b)**, not escalate. The wizard's feedback session fixes the failing check. The concerns list in the refer-back comment must enumerate the specific failing checks by name + which PR they're on.

5. **Bot gate.** Scan PR comments for unresolved automated-reviewer findings. Heuristic: look for comments from known bot accounts (e.g. `coderabbitai`, `bug-bot`, `dependabot`) where the most recent comment from that bot is not addressed (no follow-up commit since). If any open finding: **route to refer-back (step 6b)**. The concerns list enumerates each bot finding with repo + file/line + what the bot said.

6. **LLM gate — substantive code review (you, the tick LLM, do this inline).**

   The merge gate is a code review, not a checklist tick. CI green and "the file exists" are necessary conditions; the sufficient condition is that a senior reviewer would approve. Five mandatory stages. Each stage produces evidence the next stage uses; skipping any stage produces a shallow review and the gate stops adding value.

   ### Stage 6.1 — Gather full review materials

   - **Full diff per PR.** `gh pr diff <pr_url>` for each PR in `pr_urls`. NOT `gh pr view --json files` — that JSON field truncates per-file patches above ~30KB and silently drops them entirely above ~1MB; on a 5000-line bump-class PR, you'd review filenames only and not notice. The unified-diff output is what you reason over.
   - **Linear issue body** — `mcp__plugin_linear_linear__get_issue` with `id=<issue_linear_id>`. Read description + acceptance criteria fully (do not summarize and discard). **Orphan-adopted exception:** when the entry has `orphan_adopted: true` AND `issue_linear_id == null`, skip this read entirely; instead read the PR body itself (`gh pr view <pr_url> --json body --jq .body`) as the available statement of intent, and record `evidence: "orphan-adopted PR — no Linear issue context, judging against PR body and acceptance signals only"` in your working notes. If `issue_linear_id` IS set on an orphan-adopted entry (because the branch slug parsed cleanly to a known issue key), do the normal Linear fetch.
   - **Cited design docs.** Scan the issue body — or, for orphan-adopted PRs without a Linear issue, the PR body — for paths matching `docs/.*\.md` and `adr/\d+`. For each: fetch the post-PR version via the worktree (`<worktree_path>/<doc_path>`). For ADRs cited as "pinned" or "load-bearing", read in full; for subsystem docs, at minimum read the section the issue body cites. **Worktree-fallback for orphan-adopted entries:** when `worktree_paths[<repo>]` is missing or empty (a `git worktree add` failed during adoption — see step 11d), substitute every "read from worktree" with `gh api repos/<owner>/<repo>/contents/<path>?ref=<head_sha>` against the PR's head SHA (`gh pr view <pr_url> --json headRefOid --jq .headRefOid`). The `?ref=` query yields the post-PR file content, equivalent to reading from a clean worktree. The diff (`gh pr diff`) is still authoritative for what changed; only the post-PR full-file reads need this fallback.
   - **Project rules.** `<repo>/CLAUDE.md` and `<repo>/AGENTS.md` (if present), plus `<repo_parent>/CLAUDE.md` and `<repo_parent>/AGENTS.md` (workspace-level). These pin the project's anti-patterns; you'll need them in stage 6.3. The same worktree-fallback rule applies — read via `gh api contents` for orphan-adopted entries with no worktree.
   - **Cited code in its post-PR state.** Any non-trivial file in the diff — read it from the wizard's worktree, not just the patch. The patch shows the delta; the file shows whether the result is coherent. Orphan-adopted-with-no-worktree: same `gh api contents?ref=<head_sha>` fallback.

   **Diff sampling for large PRs.** If a single PR's diff exceeds ~5000 lines, you may sample — but the sample MUST cover: every `Cargo.toml` / `build.rs` / `lib.rs` / `mod.rs` / public-API file in full, every `tests/` file in full, every design-doc edit in full, plus 3–5 representative implementation files in full. Vendored-source replacements (e.g., a `vendor/<lib>/src/` swap to a known upstream tag) may be reviewed by spot-check + verifying the upstream tag matches `VENDOR_REV`. Do NOT skip the sampling and review filenames only — that is the failure mode this stage exists to prevent.

   ### Stage 6.2 — Per-file walkthrough

   For each non-trivial file in the diff (skip pure-formatting churn, regenerated lock files, and vendored-source bytes whose source-of-truth is upstream), produce one paragraph in your working notes:

   - **What changed** — the actual code or content change, in your own words. "Added struct `Foo` with field `bar: Baz`" beats "added 30 lines to foo.rs".
   - **Why** — which acceptance criterion or which design-doc section requires this change. Cite the criterion text or the doc anchor.
   - **Failure mode** — what observably breaks if this change is wrong, missing, or buggy. "Snapshots produced by this code path would have non-deterministic IDs and break the parity contract" beats "tests would fail".
   - **Test coverage** — which test in the diff (or in the existing test corpus) exercises this code path. Cite by file + test-fn name. "No test" is a flag, not a pass — note it for stage 6.5.

   This walkthrough is the substrate for stages 6.3 and 6.4. Without it, the criterion verdicts and anti-pattern checks are unfounded; you'll be reasoning from filenames.

   ### Stage 6.3 — Anti-pattern checklist

   Walk the project's stated anti-patterns against the diff. The list is sourced from the project's `CLAUDE.md` / `AGENTS.md` files; the items below are the stable archers / etherpilot-workspace set, but always re-read CLAUDE.md in case the project has added rules.

   For each item: state PASS or FAIL with a one-line citation (file:line on FAIL).

   - **Mechanical Java port.** `archers/CLAUDE.md` § "Idiomatic Rust over mechanical Java port". Scan for: class-by-class field copies that mirror a Java type's full surface, getter/setter pairs (`get_x()` / `set_x()`), `*Builder` companions for plain-data structs, `Box<dyn Trait>` hierarchies that mirror Java inheritance, ThreadLocal-style state, `Optional`-named types where `Option` would do.
   - **Non-idiomatic Rust.** `Arc<Mutex<...>>` chains where ownership transfer would suffice; index loops where iterator combinators would; `String` where a newtype would clarify role (e.g. `NodeId`, `SnapshotId`); exception-style returns (`panic!` in non-test paths) where `Result` / `Option` is the contract.
   - **AI / LLM mentions in checked-in content.** Grep the diff for `Claude`, `Generated with`, `Co-Authored-By: Claude`, `🤖`, `Anthropic`. Any hit FAILS the gate (refer-back, not escalate — the wizard can rewrite the commit/PR).
   - **Scope creep.** Files touched outside the issue's declared `repos` allowlist; files touched outside the design-doc's stated module boundaries; new dependencies not approved by the design doc; new ADRs introduced by an implementation PR (ADRs are the architect's surface, not the wizard's).
   - **Scope shortfall masquerading as N/A.** Acceptance criteria the wizard claims as N/A but that the design doc treats as load-bearing. Cross-check the criterion against the doc.
   - **Test quality.** Tests that assert only type signatures (`assert!(matches!(x, MyEnum::Variant))` without verifying state); `assert_eq!(x, x)` tautologies; `#[ignore]` without justification in the diff; tests that exercise the happy path but skip the failure path the design doc calls out.
   - **Determinism violations.** `HashMap` / `HashSet` introduced on a path the design doc requires deterministic iteration (see the project's "Determinism notes" sections); `rand`, `SystemTime`, or `Instant` used as seed material without an explicit deterministic source; canonical-bytes / canonical-hash code that depends on iteration order of a non-deterministic collection.
   - **Commit-size split.** Did the wizard split work into multiple PRs that leave intermediate states non-building or non-passing? `archers/CLAUDE.md` says "no commit-size limit" — splitting that breaks the build is itself a flag.
   - **Wire-parity violation.** For changes that touch the parity surface (canonical hashes, AF-tagged JSON, gRPC/REST shape — per ADR 0003), did the wizard re-baseline a golden hash without explanation? Is there a regression on a parity test the diff doesn't mention?

   FAIL on any item routes to refer-back (or escalate for the AI-attribution case if the cycle cap is reached).

   ### Stage 6.4 — Per-criterion verdicts

   Now produce the per-criterion verdicts. Same schema as before, **stricter evidence requirement**:

   ```
   criterion_verdicts = [
     { "criterion": "<exact text from the - [ ] line, minus the checkbox prefix>",
       "verdict":   "verified | not_verified | not_applicable",
       "reason":    "<MUST cite file:line and test-fn name; see examples below>" },
     ...
   ]
   ```

   The `reason` field MUST cite a file:line that demonstrates the criterion is met AND a test that exercises it (when the criterion has runtime behavior). Examples:

   - **Insufficient (rejected):** `"verified — handle.rs exists"` — file existence is not implementation correctness.
   - **Insufficient (rejected):** `"verified — tests pass"` — CI already gated on that; the LLM gate isn't adding value.
   - **Sufficient:** `"verified — handle.rs:42 implements Drop per BDD.md §'Refcount lifecycle'; tests/handle_drop.rs::derefs_on_drop covers the path"`.
   - **Sufficient:** `"verified — vendor/sylvan/VENDOR_REV pinned to v1.10.0 (commit 4c2d…); diff against upstream tag is byte-identical (cargo build -p archers-sylvan green confirms compile)"`.
   - **For not_applicable:** `"not_applicable — fixture criterion explicitly deferred to follow-up SOR-N+1 per the issue body's Out-of-scope section"` — cite where the deferral was sanctioned.

   If you cannot produce a citation that strong, the criterion is **not_verified**, not "verified with weaker evidence". The merge gate's value is exactly that it refuses to accept weak evidence.

   - `verified` — the diff demonstrates this criterion is satisfied (cite per the strict form above).
   - `not_verified` — criterion is not met by this diff, OR evidence is too weak. ANY `not_verified` forces refer-back (or escalate if severe).
   - `not_applicable` — the criterion legitimately doesn't apply to this implementation. Note the reason and where the deferral was sanctioned; don't hide the disagreement.

   Preserve criterion order from the issue body. If the issue has no `Acceptance criteria` section or no `- [ ]` lines, set `criterion_verdicts = []` and note it in stage 6.5's audit notes.

   ### Stage 6.4.5 — Executable AC verification (citation-existence + test-asserts-criterion)

   The stage-6.4 verdicts make the wizard *write* a citation. They do not check that the cited test-fn exists, that it asserts the claimed behavior, or that the cited file:line implements what the criterion says. The 2026-04-26 absent-functionality audit (13 placeholders shipped through the gate) is the canonical case: every placeholder PR had verdicts whose prose looked plausible because the LLM reviewer was reasoning from the citation text, not from the cited code.

   This stage MUST run after stage 6.4 produces verdicts and before stage 6.5 starts. For each verdict with `verdict == "verified"`:

   1. **Parse the citation.** From `reason`, extract:
      - The cited `file:line` of the implementation (form: `<path>:<line>`).
      - The cited test-fn (form: `<test-file>::<fn-name>` or `<test-file>::<module>::<fn-name>`).

      If the verdict cites neither (e.g. it's a vendoring criterion satisfied by a `VENDOR_REV` pin with `cargo build` evidence), skip 6.4.5 for this verdict — the stage 6.3 anti-pattern check already covered that shape. Note the skip in your working memory.

   2. **Citation-existence check (mechanical, mandatory).**
      - Run `grep -nE "<fn-name>" <test-file>` from the **wizard's worktree** if it still exists, or from the bare clone at the PR's HEAD via `git -C <bare> show <branch>:<test-file> | grep -nE "<fn-name>"`. If the function definition isn't present (no `fn <fn-name>` / `#[test]\nfn <fn-name>` / equivalent for the language), the citation is **fictitious** — flip this verdict to `not_verified` with `reason: "Stage 6.4.5: cited test-fn <fn-name> does not exist in <test-file> at PR HEAD."` Do the same check on the cited implementation file:line — if line N of the path doesn't exist (file too short, or path absent), flip to `not_verified` with `reason: "Stage 6.4.5: cited implementation file:line <path>:<line> not present at PR HEAD."`
      - The CI status `statusCheckRollup == "SUCCESS"` from step 12's pre-merge re-verification confirms the test was *executed and passed*; the citation-existence check confirms the test was *what the wizard claimed*. Together they demonstrate the cited evidence is real.

   3. **Test-asserts-criterion check (LLM judgment, focused).** Read the test-fn's body (use Read on the cited file at the cited line range, or `git show <branch>:<test-file>`). Hold the criterion text in scope and ask: *do the assertions in this test body, on the inputs they exercise, demonstrate the criterion?* Examples:
      - Criterion: "Drop on Handle releases the underlying refcount". Test asserts `assert_eq!(refcount_after_drop(), 0)` after a `drop(handle)`. PASS — the test directly exercises the claim.
      - Criterion: "Drop on Handle releases the underlying refcount". Test asserts `assert!(matches!(handle, Handle::_))`. FAIL — type-pattern check, doesn't exercise drop semantics.
      - Criterion: "Per-criterion verdicts written to Linear comment after merge". Test mocks Linear API and asserts the mock was called. PASS — the test exercises the integration the criterion describes.

      If the test body fails this check, flip the verdict to `not_verified` with `reason: "Stage 6.4.5: cited test <fn-name> exists but does not assert the criterion. Asserts: <one-sentence summary of what the test actually checks>. Criterion expected: <criterion text>."` Be specific in the rationale — the next-cycle wizard reads this to understand what to add.

   4. **State the result explicitly.** After processing every `verified` verdict, log `Stage 6.4.5: <K>/<N> verdicts pass executable verification; <FLIPPED> flipped to not_verified.` to your working notes. If `FLIPPED > 0`, those verdicts feed into stage 6.5's open-ended pass and into the decision logic — they force refer-back via the existing rule (any `not_verified` triggers refer-back).

   This stage **never runs against `not_applicable` or `not_verified` verdicts** — it only validates the wizard's positive claims. The cost is one or two grep / Read operations per `verified` verdict, plus one focused LLM judgment per cited test body. Cheap relative to the cost of merging a placeholder.

   ### Stage 6.5 — Senior-reviewer push-back pass

   **Mandatory pre-check: deferred-work comments must cite a tracking SOR identifier.** Every TODO / placeholder / deferred-work comment in production code must be rooted to a Linear issue so the deferred work is mechanically discoverable. "Documented but untracked" is the failure mode this pre-check exists to refuse — a wizard that honestly self-documents a placeholder in a module doc still ships untracked deferred work if no SOR-NNN appears in the comment.

   Grep every added or modified line in the diff for these markers (case-insensitive):

   ```regex
   TODO|FIXME|placeholder|stand-in|stub|once.+lands|once.+ships|until.+lands|for now|deferred|follow-up|Phase[ -]?[12]
   ```

   **Scope.** Production code only. Skip files under any `tests/` directory, files matching `*_test.{rs,go,py,ts,js}` / `*_tests.rs` / `*_spec.{ts,js,rb}` / `*Test.java`, and ranges inside `#[cfg(test)]` blocks (Rust). Doc files (`*.md`, `*.rst`) and design notes ARE in scope — the discipline applies workspace-wide.

   For each match: if the surrounding comment does NOT contain an `SOR-\d+` reference, append a `reviewer_observations` entry:

   - `concern`: `Deferred-work comment without SOR identifier at <file:line>: <comment text>`
   - `location`: `<file:line>`
   - `disposition`: `fix`
   - `rationale`: `Every TODO / placeholder / deferred-work comment in production code must cite a tracking SOR identifier so the deferred work is mechanically discoverable. Either remove the comment and ship the real implementation, or add an SOR-NNN cross-reference and ensure the issue exists in Linear.`

   **Refer-back verification (next cycle).** If the wizard responded by adding an `SOR-NNN` reference: verify the issue exists by calling `mcp__plugin_linear_linear__get_issue` with `id=SOR-NNN`. If the call errors, or the returned issue's `statusType` is `canceled`, refer-back again with concern `Cited SOR-NNN does not resolve to an open Linear issue`.

   This pre-check is **mandatory** and runs **before** the open-ended pass below — it does not replace it. State the result explicitly: either "0 deferred-work comments without SOR identifier" or the list of fix-disposition entries it produced.

   **Open-ended pass.** After the structured walkthrough + anti-pattern check + per-criterion verdicts + executable AC verification (6.4.5) + deferred-work pre-check, ask: **what would a senior engineer flag in code review that the structured passes missed?**

   Categories to consider (non-exhaustive):

   - **Edge cases the design doc doesn't mention** but the implementation should handle (empty inputs, max-size inputs, AF mismatches, concurrent access from where the design assumed single-threaded).
   - **Test gaps** — design says X must be tested; tests cover X happy path but not the failure paths the doc explicitly enumerates.
   - **API decisions** the wizard made that aren't in the criteria but affect downstream consumers — return-type choices, error-variant additions, lifetime bounds, sealed-trait status.
   - **Performance footguns** that don't show up in unit tests — allocation in hot paths, blocking calls in async functions, O(n²) algorithms where the design assumed O(n).
   - **Documentation rot** — the implementation diverged from the design doc in a way that's correct but undocumented; design doc needs an update PR.
   - **Future-trap-shaped patterns** — e.g., a defensive branch in production code that's dead under current wiring (the kind of pattern that becomes a stale "fall back to X" comment future readers misinterpret as a feature flag).

   Produce 0–5 additional push-back items into the `reviewer_observations` array (which may already contain entries from the deferred-work pre-check above; this is your working memory across both passes):

   ```
   reviewer_observations = [
     { "concern":     "<one-sentence description of the concern>",
       "location":    "<file:line or design-doc reference>",
       "disposition": "fix | accept | defer",
       "rationale":   "<one-sentence: why this disposition>" },
     ...
   ]
   ```

   - **fix** — must be addressed before merge. Routes to refer-back regardless of criterion verdicts.
   - **accept** — known-acceptable trade-off; merge proceeds, but the observation goes into the audit comment so it's preserved.
   - **defer** — should be tracked as a follow-up issue; merge proceeds, observation goes into the audit comment + a note that a follow-up should be filed.

   **Stating "0 items, no additional concerns" explicitly is required** — silence is ambiguous between "I checked and found nothing" and "I didn't check". Set `reviewer_observations = []` and proceed.

   ### Decision

   Combine the stage outputs:

   - **merge** — every `criterion_verdict` is `verified` or `not_applicable`, every anti-pattern check is PASS, and no `reviewer_observations` entry has `disposition: fix`. Proceed to step 6a.
   - **refer-back** — at least one `not_verified` criterion, OR an anti-pattern FAIL, OR a `reviewer_observations` entry with `disposition: fix`. Proceed to step 6b. Aggregate every failure into the concerns list.
   - **escalate** — high-severity security finding (a `reviewer_observations` entry whose concern is security-bearing AND `disposition: fix`), or anything sorcerer cannot autonomously resolve. Update entry to `status: blocked`, append to `.sorcerer/escalations.log` with `rule: review-escalation` and a description. Also escalate if `refer_back_cycle >= max_refer_back_cycles` (hard cap from `config.json:limits.max_refer_back_cycles`, default 8). `CONFLICTING` / `BEHIND` does NOT escalate — step 3 routes those to 6c (rebase) first.

   The `criterion_verdicts` and `reviewer_observations` arrays plus the anti-pattern check results are consumed by step 6a's audit comment (merge path) and step 6b's refer-back concerns list (refer-back path). Hold all three in memory until the chosen path is complete.

   ### Stage 6.6 — Second-opinion review (only when first decision == merge)

   Cluster 2 of the audit, deeper. The first reviewer's `merge` decision is the only one that ships code without further oversight. Refer-back / escalate paths give the wizard another cycle of work. Merge is irreversible. So merge alone gets a blind second opinion: a fresh `claude -p` reviewer that re-runs Stages 6.1 through 6.5 from scratch, sees the same primary sources (diff + issue + design docs + project rules), and is **NOT shown the first reviewer's verdicts**. If they converge on `merge`, the merge proceeds. If they diverge, the wizard refers back with the second reviewer's concerns appended.

   This stage runs ONLY when the first decision is `merge`. For `refer-back` or `escalate`, skip 6.6 (the wizard already gets another cycle).

   **Procedure:**

   1. Build the args. From the in-memory state for this wizard entry: `issue_key`, `issue_linear_id`, `pr_urls` (JSON object), `branch_name`, `repos` (JSON array).
   2. Invoke the second-opinion script:
      ```bash
      bash scripts/second-opinion-review.sh \
        --issue-key "<SOR-N>" \
        --issue-linear-id "<linear-uuid>" \
        --pr-urls '<{"owner/repo":"<url>",...}>' \
        --branch-name "<branch>" \
        --repos '["github.com/owner/repo",...]' \
        --project-root "$(pwd)"
      ```
      The script picks a non-throttled provider that's NOT this tick's `SORCERER_ACTIVE_PROVIDER` when one exists (different account → independent rate-limit history → less aligned bias), runs the second reviewer with read-only permission, and returns a JSON verdict on stdout.
   3. Parse the script's stdout as JSON. Read `decision`.
   4. **Compare:**
      - **Both `merge`** → second opinion concurs. Proceed to step 6a unchanged. Append `{"ts":"...","event":"second-opinion-concur","id":"<wizard-id>","issue_key":"<SOR-N>","provider":"<picked-provider>"}` to events.log.
      - **First `merge`, second `refer-back` OR `escalate`** → second opinion diverges. Treat as **refer-back** with concern `Second-opinion review disagreement: <second.summary>`. Merge the second reviewer's `criterion_verdicts` (only the `not_verified` entries) into the first reviewer's array; merge `reviewer_observations` with `disposition: fix` from second into first. Append `{"ts":"...","event":"second-opinion-diverge","id":"<wizard-id>","issue_key":"<SOR-N>","first_decision":"merge","second_decision":"<refer-back|escalate>","provider":"<picked>"}` to events.log. Proceed to step 6b instead of 6a.
   5. **If the second-opinion script fails** (non-zero exit, no parseable JSON output): log `tick: second-opinion failed for <SOR-N>; proceeding with first opinion` and proceed to step 6a as if 6.6 didn't exist. Do NOT block the merge — a hung second opinion would freeze every merge across the whole project. The script's 25-minute hard cap and provider-selection logic make this rare; an escalation isn't warranted on transient failures, but two consecutive failures on the same wizard MUST escalate with `rule: second-opinion-persistent-failure` (track via a `second_opinion_fail_count` field on the entry, increment on failure, reset on success).

   **Cost.** Doubles review LLM cost on the merge path only. Refer-back / escalate paths are unchanged. Empirically: most ticks have 0 merging wizards; merging waves cluster after CI completion. The cap on second-opinion divergence (refer-back) is the existing `max_refer_back_cycles`.

   **Why blind.** If the second reviewer sees the first's verdict, they anchor to it — the LLM's natural bias is toward consensus. The whole point of the second opinion is to catch blind spots the first reviewer's framing missed. The script enforces blindness: the prompt explicitly instructs not to read prior review notes, and the script does not pass them as inputs.

6a. **Merge action** (only when decision == merge):
   - **Pre-merge re-verification (mandatory, belt-and-suspenders).** The decision was made on data fetched at the top of step 12; a check could have flipped red in the meantime. For each PR in the set, re-fetch and confirm ALL of:
     - `state == "OPEN"` (someone didn't close/merge it externally)
     - `mergeable == "MERGEABLE"` (not CONFLICTING)
     - `mergeStateStatus == "CLEAN"` — no pending checks, no blocked state. Other values (`BEHIND`, `BLOCKED`, `DIRTY`, `DRAFT`, `UNSTABLE`, `HAS_HOOKS`) are all "not safe to merge right now" for different reasons.
     - Every `statusCheckRollup` entry has `conclusion == "SUCCESS"` or `SKIPPED`.

     If any PR fails re-verification: do NOT merge. Log `tick: PR <url> failed pre-merge re-verification (<reason>); deferring`. Leave the wizard at `awaiting-review`; next tick re-evaluates from scratch.

   - **Synchronous merge (NOT --auto).** `--auto` hands off to GitHub's branch-protection rules; if those aren't configured correctly on the target repo, `--auto` merges immediately regardless of check state. We've done the gating ourselves; use synchronous merge so any failure is visible in this tick:
     ```bash
     gh pr merge "<pr_url>" --squash --delete-branch
     ```
     For each PR (in `merge_order` if declared, else any order). If `gh pr merge` fails for any reason (branch protection rejects, checks flipped red between re-verify and merge, network blip): log the failure, do NOT continue merging subsequent PRs in the set (partial-merge state is the worst outcome), and leave the wizard at `awaiting-review`. Append an escalation with `rule: merge-rejected-after-gates` including the gh error. Next tick re-evaluates.

   - **Audit trail (post-merge, best-effort).** Once every PR in the set has merged successfully, write the per-criterion verdict (from step 6's `criterion_verdicts` array) where humans and future ticks can see it. The merge commits are already done — these writes only fail loudly in logs, never unwind the merge.

     1. **Linear comment with full verdict.** Build a markdown body and post via `mcp__plugin_linear_linear__save_comment` with `issueId=<issue_linear_id>`. The body has three subsections — per-criterion verdict, anti-pattern check, reviewer observations — so the structured rationale collected across stages 6.3 / 6.4 / 6.5 is preserved alongside the merge:
        ```markdown
        ## sorcerer review: merged

        Per-criterion verdict:

        - ✅ <criterion text>: <reason — file:line + test-fn name>
        - ✅ <criterion text>: <reason>
        - N/A <criterion text>: <reason — why not applicable; cite where deferral was sanctioned>

        Anti-pattern check:

        - ✅ Mechanical Java port: <one-line citation, or "no relevant changes">
        - ✅ Non-idiomatic Rust: <one-line citation>
        - ✅ AI / LLM mentions: <one-line citation, or "no matches">
        - ✅ Scope creep: <one-line citation>
        - ✅ Scope shortfall masquerading as N/A: <one-line citation>
        - ✅ Test quality: <one-line citation>
        - ✅ Determinism violations: <one-line citation>
        - ✅ Commit-size split: <one-line citation>
        - ✅ Wire-parity violation: <one-line citation>

        Reviewer observations:

        - [accept] <concern> (at <location>): <rationale>
        - [defer] <concern> (at <location>): <rationale> — follow-up issue recommended
        ```
        Map the in-memory verdicts: `verified` → `✅`, `not_applicable` → `N/A`. (Merge path implies no `not_verified` — if any present, the decision should have been refer-back; treat as a bug and emit `❌` on the line so the audit is honest, but still proceed since the merge already happened.) When `criterion_verdicts` is empty (issue had no checkbox criteria), include a single line under the verdict subsection: `_No checkbox acceptance criteria found in the issue body — review approved on overall judgment._` so the absence is recorded explicitly rather than implied by silence.

        For the **Anti-pattern check** subsection: every item from stage 6.3's checklist appears, even when PASS — silence on an item is ambiguous between "checked, clean" and "didn't check". On PASS with no relevant changes, write "no relevant changes" rather than omitting the line.

        For the **Reviewer observations** subsection: every entry in `reviewer_observations` appears, prefixed with its `disposition` (`[accept]` or `[defer]` — `[fix]` entries should have routed to refer-back, not merge). Omit the subsection entirely only when `reviewer_observations` is empty; in that case, emit a single line `_No additional concerns beyond the structured passes._` so the explicit no-concerns finding is recorded.

     2. **Linear issue body — tick verified criteria.** Re-fetch the issue's current `description` via `mcp__plugin_linear_linear__get_issue` immediately before this update — DO NOT reuse the description from step 6's fetch. Seconds have elapsed and a webhook from the just-merged PRs may have appended to the body; reusing the stale copy would clobber those edits on save. Apply the ticks against the freshly-fetched body. For each verdict with `verified`, replace the matching `- [ ] <criterion>` line with `- [x] <criterion>` — match by **trimmed** equality (strip leading/trailing whitespace from both sides of the comparison), single replacement per criterion (leftmost match), preserving the line's original whitespace exactly in the output. Do NOT modify lines for `not_applicable` or `not_verified` verdicts — the comment carries that nuance; ticking N/A would erase the distinction. Save via `mcp__plugin_linear_linear__save_issue` with `id=<issue_linear_id>` and `description=<updated body>`. If no `- [ ]` line matches a verified criterion (criterion text drifted), log `tick: criterion text drift on <issue_key> — comment posted, body unchanged for "<criterion>"` and proceed — the comment is the canonical record and is unaffected.

     3. **Per-PR pointer comment.** For each PR in the set:
        ```bash
        gh pr comment "<pr_url>" --body "Reviewed and approved by sorcerer. Per-criterion verdict on Linear: <linear-issue-url>"
        ```
        Resolve `<linear-issue-url>` from the issue object's `url` field. This makes the GitHub-side review state non-opaque — anyone viewing the merged PR sees the explicit approval pointer.

     If any of these three writes errors (Linear API blip, gh CLI failure): log the specific failure (`tick: audit-write failed for <issue_key>: <step>: <error>`) and continue to the next sub-step. Don't unwind the merge, don't escalate — the merge has already shipped. The next tick won't re-attempt audit writes (state has moved past `awaiting-review`); operators looking at a missing-audit issue can re-run the comment manually.

   - Update entry: `status: merging`, `review_decision: merge`.
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"review-merge","id":"<wizard-id>","issue_key":"<SOR-N>","pr_count":<N>,"verified_count":<N>,"na_count":<N>}
     ```
     `verified_count` and `na_count` are derived from `criterion_verdicts`; `0`/`0` is valid (issue had no checkbox criteria).
   - Print to **stdout**: `Reviewed and merged: <issue_key> (<N> PR(s)). Verdict: <V> verified, <NA> N/A.`

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
     nohup bash "$SORCERER_REPO/scripts/spawn-wizard.sh" feedback \
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

6c. **Rebase action** (only when step 3 flagged `CONFLICTING` / `BEHIND` / `DIRTY`):
   - Increment `conflict_cycle` on the entry (initialize to 0 if absent, so first conflict sets it to 1).
   - Check the cap: if `conflict_cycle > max_refer_back_cycles`, treat as escalate (rule: `conflict-cap-reached`). Otherwise continue.
   - **Update `<state_dir>/meta.json`** — add `pr_urls` + `conflict_cycle` fields so the rebase wizard's context-builder has them:
     ```bash
     jq --argjson pr_urls '<pr_urls JSON object>' --argjson cycle <N> \
        '. + {pr_urls: $pr_urls, conflict_cycle: $cycle}' \
        <state_dir>/meta.json > <state_dir>/meta.json.tmp \
       && mv <state_dir>/meta.json.tmp <state_dir>/meta.json
     ```
   - **Spawn the rebase wizard** (detached):
     ```bash
     nohup bash "$SORCERER_REPO/scripts/spawn-wizard.sh" rebase \
       --wizard-id <wizard-id-same-as-implement> \
       --issue-meta-file <state_dir>/meta.json \
       > <state_dir>/logs/rebase-<N>.txt 2>&1 &
     echo $!
     ```
     Note: reuses the same wizard-id as the implement wizard (single active_wizards entry per issue; status tracks phase).
   - Update entry: `status: running`, `review_decision: null`, `pid: <new pid>`. Touch the wizard's heartbeat timer (reset).
   - Append to `.sorcerer/events.log`:
     ```json
     {"ts":"...","event":"review-rebase","id":"<wizard-id>","issue_key":"<SOR-N>","cycle":<N>,"offending_repos":["<repo>"]}
     ```
   - Print to **stdout**: `Rebase needed: <issue_key> (cycle <N>). Rebase wizard spawned for <N> repo(s).`

**Step 5c reminder.** When the rebase wizard exits, step 5c (implement/feedback/rebase completion detection) handles it with the same pattern as feedback. `REBASE_OK` in the latest log → transition back to `awaiting-review` for step 12 to re-try. `REBASE_FAILED` → escalate with `rule: rebase-self-reported-failure`. The completion detection's log-tail inspection already covers `logs/rebase-<N>.txt` via its `ls -t <state_dir>/logs/*.txt` pattern.

