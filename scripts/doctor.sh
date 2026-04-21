#!/usr/bin/env bash
# Sorcerer preflight check. Exits 0 if everything required is in place; non-zero on any failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; RESET=''
fi

PASS=0; FAIL=0; WARN=0

ok()      { printf "  ${GREEN}PASS${RESET}  %s\n" "$1"; PASS=$((PASS+1)); }
no()      { printf "  ${RED}FAIL${RESET}  %s\n" "$1"; FAIL=$((FAIL+1)); }
warn()    { printf "  ${YELLOW}WARN${RESET}  %s\n" "$1"; WARN=$((WARN+1)); }
section() { printf "\n${YELLOW}== %s ==${RESET}\n" "$1"; }

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "$1 present"
  else
    no "$1 not found on PATH"
  fi
}

# === CLI tools ===
section "CLI tools"
for c in git claude gh jq curl openssl python3; do check_cmd "$c"; done

# === Source ~/.shell_env (always, to pick up the latest values even if a parent process
#     inherited stale ones from before .shell_env was edited) ===
if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.shell_env"
fi

# === Linear MCP ===
section "Linear MCP"
if claude mcp list 2>/dev/null | grep -qE 'linear.*✓ Connected'; then
  ok "Linear MCP connected"
else
  no "Linear MCP not connected"
fi

# === GitHub App env ===
section "GitHub App"
for var in GH_APP_APP_ID GH_APP_CLIENT_ID GH_APP_PRIVATE_KEY_PATH; do
  if [[ -n "${!var:-}" ]]; then ok "$var set"; else no "$var not set"; fi
done

if [[ -n "${GH_APP_PRIVATE_KEY_PATH:-}" ]]; then
  if [[ -f "$GH_APP_PRIVATE_KEY_PATH" ]]; then
    perm=$(stat -c '%a' "$GH_APP_PRIVATE_KEY_PATH" 2>/dev/null || stat -f '%Lp' "$GH_APP_PRIVATE_KEY_PATH" 2>/dev/null)
    if [[ "$perm" == "600" ]]; then
      ok "private key permissions 600"
    else
      no "private key permissions $perm (must be 600)"
    fi
  else
    no "private key not found at $GH_APP_PRIVATE_KEY_PATH"
  fi
fi

# === Token refresh + validity ===
section "GitHub token"
if [[ ! -x "$REPO_ROOT/scripts/refresh-token.sh" ]]; then
  no "scripts/refresh-token.sh not executable (chmod +x it)"
else
  if TOKEN_OUT=$(bash "$REPO_ROOT/scripts/refresh-token.sh" 2>&1); then
    if grep -q '^export GITHUB_TOKEN=' <<<"$TOKEN_OUT"; then
      ok "scripts/refresh-token.sh minted a token"
      eval "$TOKEN_OUT"
      if installs=$(gh api /installation/repositories 2>/dev/null); then
        owner=$(jq -r '.repositories[0].owner.login // "unknown"' <<<"$installs")
        count=$(jq -r '.total_count // 0' <<<"$installs")
        ok "token authenticates against GitHub API ($count repo(s) accessible, install on $owner)"
      else
        no "minted token failed gh api /installation/repositories — token invalid or App not installed"
      fi
    else
      no "scripts/refresh-token.sh produced no GITHUB_TOKEN line"
      printf "    output: %s\n" "$TOKEN_OUT" >&2
    fi
  else
    no "scripts/refresh-token.sh exited non-zero"
    printf "    output: %s\n" "$TOKEN_OUT" >&2
  fi
fi

# === config.yaml ===
section "Configuration"
REPOS=""; EXPLORABLE=""
if [[ ! -f "$REPO_ROOT/config.yaml" ]]; then
  warn "config.yaml not found — copy config.yaml.example to config.yaml and fill in"
else
  ok "config.yaml present"
  if command -v python3 >/dev/null 2>&1; then
    REPOS=$(python3 - "$REPO_ROOT/config.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
for r in d.get('repos') or []:
    print(r)
PY
)
    EXPLORABLE=$(python3 - "$REPO_ROOT/config.yaml" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f) or {}
for r in d.get('explorable_repos') or []:
    print(r)
PY
)
  fi
fi

# === Bare clones ===
section "Bare clones"
if [[ -n "$EXPLORABLE" ]]; then
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    repo_no_host="${repo#github.com/}"
    bare="$REPO_ROOT/repos/${repo_no_host//\//-}.git"
    if [[ -d "$bare" ]]; then
      ok "bare clone present for $repo"
    else
      no "missing bare clone for $repo (expected at $bare)"
    fi
  done <<<"$EXPLORABLE"
else
  warn "no explorable_repos to check (config.yaml missing or empty)"
fi

# === Repo access via App token ===
section "Repo access"
declare -A REPO_INFO
if [[ -n "${GITHUB_TOKEN:-}" && -n "$REPOS" ]]; then
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    repo_no_host="${repo#github.com/}"
    if info=$(gh api "repos/$repo_no_host" 2>/dev/null); then
      ok "App can read $repo"
      REPO_INFO["$repo_no_host"]="$info"
    else
      no "App cannot read $repo (install the App on this repo)"
    fi
  done <<<"$REPOS"
else
  warn "skipped — need both a valid GITHUB_TOKEN and a repos list in config.yaml"
fi

# === Branch protection + auto-merge on each target repo ===
section "Merge gate (target repos)"
if [[ ${#REPO_INFO[@]} -gt 0 ]]; then
  for repo_no_host in "${!REPO_INFO[@]}"; do
    info="${REPO_INFO[$repo_no_host]}"
    default_branch=$(jq -r '.default_branch' <<<"$info")
    auto_merge=$(jq -r '.allow_auto_merge' <<<"$info")
    delete_branch=$(jq -r '.delete_branch_on_merge' <<<"$info")

    # Branch protection check (works without Administration permission via the basic branches endpoint)
    if branch_info=$(gh api "repos/$repo_no_host/branches/$default_branch" 2>/dev/null); then
      protected=$(jq -r '.protected' <<<"$branch_info")
      if [[ "$protected" == "true" ]]; then
        ok "$repo_no_host: branch protection on $default_branch"
      else
        no "$repo_no_host: $default_branch has NO branch protection (Settings → Branches → Add rule)"
      fi
    else
      no "$repo_no_host: cannot inspect $default_branch (token may lack access)"
    fi

    if [[ "$auto_merge" == "true" ]]; then
      ok "$repo_no_host: auto-merge enabled"
    else
      no "$repo_no_host: auto-merge disabled (Settings → General → Pull Requests → Allow auto-merge)"
    fi

    if [[ "$delete_branch" == "true" ]]; then
      ok "$repo_no_host: head branches auto-deleted on merge"
    else
      warn "$repo_no_host: head branches not auto-deleted (cosmetic; sorcerer can pass --delete-branch on merge)"
    fi
  done
else
  warn "skipped — needs at least one accessible repo from config.yaml"
fi

# === State + space ===
section "State directory"
if [[ -d "$REPO_ROOT/state" ]]; then
  if [[ -w "$REPO_ROOT/state" ]]; then
    ok "state/ writable"
  else
    no "state/ not writable"
  fi
else
  warn "state/ does not exist yet (will be created on first run)"
fi
avail_kb=$(df -Pk "$REPO_ROOT" | awk 'NR==2 {print $4}')
if (( avail_kb > 1048576 )); then
  ok "free space: $((avail_kb/1024)) MB"
else
  no "free space: $((avail_kb/1024)) MB (need >1024 MB)"
fi

# === Anthropic CLI ===
section "Anthropic CLI"
if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then
  ok "claude CLI installed ($(claude --version 2>/dev/null | head -1))"
else
  no "claude CLI missing or broken"
fi

# === Summary ===
printf "\n${YELLOW}== Summary ==${RESET}  ${GREEN}%d pass${RESET}, ${RED}%d fail${RESET}, ${YELLOW}%d warn${RESET}\n" "$PASS" "$FAIL" "$WARN"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
