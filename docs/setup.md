# Setup

Access requirements and setup steps. **user** = human action; **auto** = coordinator-handled.

## Prerequisites

Hard requirements. `scripts/doctor.sh` refuses to pass if any is missing.

- Linux, macOS, or WSL.
- Git 2.40+.
- `claude` CLI 2.1.1+.
- `gh` CLI 2.40+.
- `jq`, `curl`, `openssl`, `uuidgen` (used by `scripts/refresh-token.sh`, `scripts/spawn-wizard.sh`, `scripts/doctor.sh`, and the coordinator tick).
- `shellcheck` (used by `scripts/lint.sh`).
- **Linear MCP server** installed and connected in Claude Code (`claude mcp list` shows Linear with `✓ Connected`).
- **GitHub App** installed on every repo in both `repos` and `explorable_repos`, with a private key on disk and the refresh script wired up.
- Anthropic API key accessible to `claude`.

## Two-tier repo allowlist

Sorcerer has two lists in `config.json`:

- `repos` — repos sorcerer may open PRs in and merge to. Every issue's `repos: [...]` must be a subset of this list.
- `explorable_repos` — superset of `repos`; repos sorcerer may **read** during design (architect exploration, Tier-2 decomposition). The App must be installed on every one.

If a design wants to touch a repo that's only in `explorable_repos` (not in `repos`), the designer escalates — the user decides whether to promote that repo to `repos`.

## GitHub access

Sorcerer uses `gh` CLI. `gh` reads `$GITHUB_TOKEN` on every invocation. `$GITHUB_TOKEN` is a GitHub App installation token (1-hour TTL) minted by `scripts/refresh-token.sh` from the App's private key.

### One-time GitHub App setup (user)

1. In the account/org that owns your target repos, create a GitHub App.
2. Required **repository** permissions:
   - Metadata: Read
   - Contents: **Read and write** *(branches, commits, reading workflow YAML)*
   - Pull requests: **Read and write**
   - Issues: Read
   - Actions: Read *(workflow runs, jobs, logs — this is what CI polling uses)*
   - Checks: Read
   - Commit statuses: Read
   - Workflows: **No access** *(this permission only controls editing `.github/workflows/*.yml`; sorcerer must never do that. Reading workflow files is already covered by Contents: Read. There is no read-only tier for this permission by design.)*
3. Webhooks: disabled. Sorcerer polls.
4. Install the App on **every** repo that will appear in either `repos` or `explorable_repos`. Only those repos.
5. Save the App's private key to `$HOME/.keys/<app>.private-key.pem` at mode 600.
6. Export in your shell profile:
   ```
   export GH_APP_CLIENT_ID=<client-id>
   export GH_APP_APP_ID=<numeric-app-id>
   export GH_APP_PRIVATE_KEY_PATH=$HOME/.keys/<app>.private-key.pem
   ```

### Token refresh at runtime

The script `scripts/refresh-token.sh` (in this repo) mints installation tokens from the App's private key. It depends only on `curl`, `jq`, and `openssl` — no cross-repo dependencies.

**user**: before launching the coordinator for the first time:
```
source <(bash scripts/refresh-token.sh)
```

**auto**: each tick, the coordinator inspects the token's expiry. <10min remaining → re-runs the script and updates its own env. Spawned sessions inherit the fresh token.

### Per-repo GitHub setup (user, once per repo in `repos`)

Branch protection on the default branch is the primary safety mechanism. Configure before adding a repo to `repos`.

1. `https://github.com/<owner>/<repo>/settings/branches`.
2. Add a rule for the default branch.
3. Enable **Require a pull request before merging**.
4. Enable **Require status checks to pass before merging**; select required CI checks.
5. Enable **Require branches to be up to date before merging**.
6. Enable **Do not allow bypassing the above settings**.
7. `Settings → General → Pull Requests`: enable **Allow auto-merge** and **Automatically delete head branches**.

Repos in `explorable_repos` but not in `repos` need only the App installed — sorcerer reads them but never writes.

### Bare clones for every explorable repo

Wizards use `git worktree`s off bare clones — one worktree per (issue × affected repo). **auto**: sorcerer creates each bare clone automatically on first use via `scripts/ensure-bare-clones.sh`, which mints the right per-owner App token and clones over HTTPS. You do nothing. The clones live under `repos/<owner>-<repo>.git/`.

The doctor reports bare-clone state as a NOTE (not a failure) — it just tells you which ones will be fetched on the next sorcerer run. Stale or corrupted bare clones still require manual recreation (delete the directory; sorcerer will re-clone).

## Linear access

Linear MCP is already connected (`claude mcp list | grep linear` must show `✓ Connected`). If not, configure it via Claude Code's plugin flow before continuing — sorcerer has no Linear access otherwise.

### Team identifier (user)

1. Open any issue in the target Linear team. URL ends `/issue/<TEAM>-<NUM>/...` — `<TEAM>` is the team key.
2. Add to `config.json`:
   ```json
   {
     "linear": {
       "default_team_key": "ENG",
       "wizard_label":     "wizard"
     }
   }
   ```

**auto**: first run resolves `default_team_key` → team UUID via `list_teams`, caches in `<project>/.sorcerer/sorcerer.json`.

### Linear-GitHub integration (user, recommended)

**Settings → Integrations → GitHub → Connect** in Linear. Authorize and select every repo in `repos`.

With this active, Linear auto-links PRs that reference issue IDs. Sorcerer uses `Part of <TEAM-NUM>` (not `Closes`) in PR bodies, so Linear links but does not auto-close. Sorcerer closes the issue itself once the full PR set has merged.

## Anthropic API

The `claude` CLI uses configured auth (`~/.claude` or `$ANTHROPIC_API_KEY`). No sorcerer-specific step.

Verify:
```
claude --version && claude -p "echo ready"
```

## Minimal `config.json`

```json
{
  "repos": [
    "github.com/acme/widget-api",
    "github.com/acme/widget-web"
  ],
  "explorable_repos": [
    "github.com/acme/widget-api",
    "github.com/acme/widget-web",
    "github.com/acme/shared-protos",
    "github.com/acme/deployment-config"
  ],
  "linear": {
    "default_team_key": "ENG",
    "wizard_label":     "wizard"
  },
  "models": {
    "coordinator":        "claude-opus-4-7",
    "architect":          "claude-opus-4-7",
    "designer":           "claude-opus-4-7",
    "executor":           "claude-opus-4-7",
    "reviewer":           "claude-opus-4-7",
    "reviewer_architect": "claude-opus-4-7",
    "reviewer_design":    "claude-opus-4-7"
  },
  "effort": {
    "coordinator":        "xhigh",
    "architect":          "xhigh",
    "designer":           "xhigh",
    "executor":           "high",
    "reviewer":           "xhigh",
    "reviewer_architect": "max",
    "reviewer_design":    "max"
  },
  "architect": {
    "auto_threshold": {
      "min_repos": 3,
      "min_issues_estimate": 12
    }
  },
  "limits": {
    "max_concurrent_wizards": 3,
    "max_refer_back_cycles":  5
  },
  "merge": {
    "strategy":      "squash",
    "delete_branch": true
  }
}
```

Field notes:
- `repos` — mergeable targets.
- `explorable_repos` — readable during design; must be a superset of `repos`.
- `architect.auto_threshold` — auto-invoke Tier 1 when the request is expected to touch `min_repos`+ repos or produce `min_issues_estimate`+ issues.
- `merge.strategy` — one of `squash | merge | rebase`.
- `effort.<role>` — passed to `claude -p --effort <level>`. Valid values: `low | medium | high | xhigh | max`. `xhigh` only works on Opus 4.7+; older models accept up to `high`. Roles map to wizard modes:
  - `coordinator` — the tick loop itself
  - `architect` — Tier-1 architect sessions
  - `designer` — Tier-2 design sessions
  - `executor` — Tier-3 implement / feedback / rebase sessions (all share this setting)
  - `reviewer` — PR-set review; runs inline in the coordinator tick today (so effectively uses `coordinator` effort at runtime), but the field is honored once review moves to its own spawn
  - `reviewer_architect` — reserved for a future architect-output reviewer (validates `plan.json` + cross-sub-epic contracts before Tier-2 fan-out)
  - `reviewer_design` — reserved for a future design-output reviewer (validates the Linear epic + `manifest.json` before Tier-3 dispatch)

  Omit a role (or set it to `""`) to defer to the claude CLI's own default — useful on older CLIs that lack `--effort`. The `reviewer_*` roles are schema stubs today: they are wired through config so projects can pre-set the level they want when those reviewers come online, without a later schema migration.

  **Default rationale.** Every role defaults to `claude-opus-4-7` for the model. Effort is tuned against Opus 4.7's full range (`low | medium | high | xhigh | max`):

  - **Planners** — `coordinator`, `architect`, `designer` → `xhigh`. Planning work is where sorcerer's decisions compound; extra depth per session is the single highest-leverage spend.
  - **Executor** → `high`. Implementation runs by far the most sessions per epic, so it's the biggest cost driver; `high` is enough for pattern-following coding work, and the reviewer catches deeper issues downstream. Bump to `xhigh` if your implementation work is architecturally novel (new service, new protocol) rather than feature-follow.
  - **Reviewers** are set one level above the role they review, not a flat maximum. A same-effort reviewer rubber-stamps; a one-notch bump keeps the gate meaningful without wasting spend.
    - `reviewer` reviews executor output (PR diffs) → `xhigh` (executor is `high`).
    - `reviewer_architect` reviews architect output (`plan.json` + cross-sub-epic contracts) → `max` (architect is `xhigh`).
    - `reviewer_design` reviews designer output (`manifest.json` + Linear issues) → `max` (designer is `xhigh`).

    If you adjust a producer's effort, bump the matching reviewer by one level yourself — the relationship is enforced by convention, not by code.

  Adjust any role downward if you're pinning to a model that doesn't support the higher levels (e.g. Sonnet 4.6 tops out at `high`; set executor's model to `claude-sonnet-4-6` and its effort stays at `high`).
- JSON has no comments — refer to these notes or `config.json.example` for reference field semantics.

## Verification

```
bash scripts/doctor.sh
```
Fails on:
- `claude`, `git`, `gh`, `jq`, `curl`, `openssl` missing or out of date.
- Linear MCP not connected.
- `$GH_APP_PRIVATE_KEY_PATH` unset or wrong permissions.
- `scripts/refresh-token.sh` not runnable.
- `$GITHUB_TOKEN` invalid now, or doesn't cover every repo in `explorable_repos`.
- Any repo in `repos` without branch protection + auto-merge.
- Any repo in `explorable_repos` without a bare clone under `repos/`.
- `state/` unwritable or <1GB free.
- Anthropic API key missing.

Fix anything fatal before starting `/loop`.

## Reducing merge conflicts on shared docs

Sorcerer can run many wizards in parallel; each opens a PR against the same default branch. Shared append-only docs (STATUS.md, CHANGELOG.md, a progress roadmap, `.gitattributes` itself) tend to cause conflicts when two wizards append at the end.

Sorcerer handles real conflicts automatically: tick step 12 detects `mergeable == CONFLICTING` or `mergeStateStatus in [BEHIND, DIRTY]`, spawns a `rebase` wizard that rebases onto the current default branch and resolves conflicts in each affected repo, and re-queues the PR set for review. Works for both text-additive docs (keep both sides) and code conflicts (re-apply wizard intent on top of upstream).

For files where "both sides win" is almost always the right answer, you can skip the rebase cycle entirely by declaring a union merge in the repo's `.gitattributes`:

```gitattributes
STATUS.md         merge=union
CHANGELOG.md      merge=union
docs/roadmap.md   merge=union
```

`merge=union` tells git to auto-resolve the conflict by keeping BOTH sides of each hunk, preserving both additions. Only use it on files where the semantics are additive and line-order doesn't encode meaning — it is a LOSSY strategy for structured content (think JSON, YAML, code).

For structured files (config, code, anything parsed), leave the default merge driver and let sorcerer's rebase wizard handle it.

## One-time checklist

- [ ] Install `git`, `claude`, `gh`, `jq`, `curl`, `openssl`, `uuidgen`, `shellcheck`.
- [ ] Confirm Linear MCP connected.
- [ ] Create a GitHub App with the permissions above; install on every repo in `explorable_repos`; save private key at mode 600.
- [ ] Export `GH_APP_CLIENT_ID`, `GH_APP_APP_ID`, `GH_APP_PRIVATE_KEY_PATH` in shell profile.
- [ ] Verify `bash scripts/refresh-token.sh` emits a valid token.
- [ ] Configure branch protection + auto-merge on every repo in `repos`.
- [ ] (Recommended) Connect Linear's GitHub integration.
- [ ] Run `bash scripts/install-skill.sh`. This symlinks the `/sorcerer` skill into `~/.claude/skills/`, pre-approves its Bash invocation, writes `SORCERER_REPO` into `~/.shell_env`, and **auto-installs the `/wizard` skill** from [vlad-ko/claude-wizard](https://github.com/vlad-ko/claude-wizard) (MIT) via its upstream `install.sh`. If `/wizard` is already present, the step is a no-op.
- [ ] Fill in `<project>/.sorcerer/config.json` (repos, explorable_repos, team key, models, architect thresholds, limits). Auto-bootstrapped on first `/sorcerer` call in a project; edit from the template if you need multi-repo or a non-default Linear team.
- [ ] `bash scripts/doctor.sh` passes clean (bare clones auto-created on first use; doctor reports pending ones as NOTE; `/wizard` skill presence is verified).
