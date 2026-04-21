# Setup

Access requirements and setup steps. **user** = human action; **auto** = coordinator-handled.

## Prerequisites

Hard requirements. `scripts/doctor.sh` refuses to pass if any is missing.

- Linux, macOS, or WSL.
- Git 2.40+.
- `claude` CLI 2.1.1+.
- `gh` CLI 2.40+.
- `jq`, `curl`, `openssl`, `python3` (used by `scripts/refresh-token.sh` and `scripts/doctor.sh`).
- `shellcheck` (used by `scripts/lint.sh`).
- **Linear MCP server** installed and connected in Claude Code (`claude mcp list` shows Linear with `✓ Connected`).
- **GitHub App** installed on every repo in both `repos` and `explorable_repos`, with a private key on disk and the refresh script wired up.
- Anthropic API key accessible to `claude`.

## Two-tier repo allowlist

Sorcerer has two lists in `config.yaml`:

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
2. Add to `config.yaml`:
   ```yaml
   linear:
     default_team_key: ENG
     wizard_label: wizard
   ```

**auto**: first run resolves `default_team_key` → team UUID via `list_teams`, caches in `state/sorcerer.yaml`.

### Linear-GitHub integration (user, recommended)

**Settings → Integrations → GitHub → Connect** in Linear. Authorize and select every repo in `repos`.

With this active, Linear auto-links PRs that reference issue IDs. Sorcerer uses `Part of <TEAM-NUM>` (not `Closes`) in PR bodies, so Linear links but does not auto-close. Sorcerer closes the issue itself once the full PR set has merged.

## Anthropic API

The `claude` CLI uses configured auth (`~/.claude` or `$ANTHROPIC_API_KEY`). No sorcerer-specific step.

Verify:
```
claude --version && claude -p "echo ready"
```

## Minimal `config.yaml`

```yaml
repos:                             # mergeable targets
  - github.com/acme/widget-api
  - github.com/acme/widget-web

explorable_repos:                  # readable during design (superset of repos)
  - github.com/acme/widget-api
  - github.com/acme/widget-web
  - github.com/acme/shared-protos
  - github.com/acme/deployment-config

linear:
  default_team_key: ENG
  wizard_label: wizard

models:
  coordinator: claude-opus-4-7
  architect: claude-opus-4-7
  designer: claude-opus-4-7
  executor: claude-opus-4-7
  reviewer: claude-opus-4-7

architect:
  # Auto-invoke Tier 1 when the request looks this big.
  auto_threshold:
    min_repos: 3                   # request likely touches ≥ this many repos
    min_issues_estimate: 12        # ...or estimated to produce ≥ this many issues

limits:
  max_concurrent_wizards: 3
  max_refer_back_cycles: 5

merge:
  strategy: squash                 # squash | merge | rebase
  delete_branch: true
```

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

## One-time checklist

- [ ] Install `git`, `claude`, `gh`, `jq`, `curl`, `openssl`, `shellcheck`.
- [ ] Confirm Linear MCP connected.
- [ ] Create a GitHub App with the permissions above; install on every repo in `explorable_repos`; save private key at mode 600.
- [ ] Export `GH_APP_CLIENT_ID`, `GH_APP_APP_ID`, `GH_APP_PRIVATE_KEY_PATH` in shell profile.
- [ ] Verify `bash scripts/refresh-token.sh` emits a valid token.
- [ ] Configure branch protection + auto-merge on every repo in `repos`.
- [ ] (Recommended) Connect Linear's GitHub integration.
- [ ] Fill in `config.yaml` (repos, explorable_repos, team key, models, architect thresholds, limits).
- [ ] `bash scripts/doctor.sh` passes clean (bare clones auto-created on first use; doctor reports pending ones as NOTE).
