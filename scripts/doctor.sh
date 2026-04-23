#!/usr/bin/env bash
# Sorcerer preflight check for a project. Exits 0 if everything required is
# in place; non-zero on any failure.
#
# Usage: scripts/doctor.sh [<project-root>]
#
# If <project-root> is omitted, uses cwd. Checks the project's .sorcerer/
# layout (config.json, bare clones, state/ writable) plus user-level
# prerequisites (CLI tools, Linear MCP, GitHub App env, Anthropic CLI).
set -o pipefail   # intentionally NOT -u: associative arrays misbehave with set -u across empty states

PROJECT_ROOT="${1:-$(pwd)}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a directory: $PROJECT_ROOT" >&2; exit 1; }
cd "$PROJECT_ROOT"
STATE=".sorcerer"

# Source user-level shell env FIRST so subsequent checks see SORCERER_REPO,
# GH_APP_*, LINEAR_API_KEY, etc. The doctor is often invoked from a fresh
# subshell that hasn't sourced anything.
if [[ -f "$HOME/.shell_env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.shell_env"
fi

: "${SORCERER_REPO:=}"

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

echo "sorcerer doctor for: $PROJECT_ROOT"

# === CLI tools ===
section "CLI tools"
for c in git claude gh jq curl openssl uuidgen; do check_cmd "$c"; done

# === $SORCERER_REPO ===
section "SORCERER_REPO"
if [[ -z "$SORCERER_REPO" ]]; then
  no "SORCERER_REPO not set (add 'export SORCERER_REPO=/path/to/sorcerer/tool' to ~/.shell_env)"
elif [[ ! -d "$SORCERER_REPO" ]]; then
  no "SORCERER_REPO points to a missing dir: $SORCERER_REPO"
elif [[ ! -f "$SORCERER_REPO/scripts/sorcerer-submit.sh" ]]; then
  no "$SORCERER_REPO doesn't look like a sorcerer tool dir (missing scripts/sorcerer-submit.sh)"
else
  ok "SORCERER_REPO set: $SORCERER_REPO"
fi

# === /wizard skill ===
section "/wizard skill"
WIZARD_SKILL="$HOME/.claude/skills/wizard/SKILL.md"
if [[ -f "$WIZARD_SKILL" ]]; then
  ok "/wizard skill installed at $WIZARD_SKILL"
else
  no "/wizard skill missing — run 'bash $SORCERER_REPO/scripts/install-skill.sh' (auto-installs from vlad-ko/claude-wizard) or 'curl -sL https://raw.githubusercontent.com/vlad-ko/claude-wizard/main/install.sh | bash'"
fi

# === Provider cycling (config.providers) ===
section "Provider slots"
if [[ ! -f "$STATE/config.json" ]]; then
  warn "skipped — $STATE/config.json not bootstrapped yet"
else
  provider_count=$(jq -r '(.providers // []) | length' "$STATE/config.json")
  if [[ "$provider_count" == "0" ]]; then
    warn "no providers configured — sorcerer will use ambient auth only (no cycling on 429)"
  else
    ok "$provider_count provider slot(s) declared in $STATE/config.json"
    # For each ${VAR} reference in any provider's env map, check that VAR is set.
    while IFS=$'\t' read -r prov_name key val; do
      [[ -z "$prov_name" ]] && continue
      if [[ "$val" =~ ^\$\{(.+)\}$ ]]; then
        varname="${BASH_REMATCH[1]}"
        if [[ -n "${!varname:-}" ]]; then
          ok "  provider $prov_name: \$$varname is set"
        else
          no "  provider $prov_name: \$$varname referenced by env.$key but NOT set in the shell (add 'export $varname=...' to ~/.shell_env)"
        fi
      fi
    done < <(jq -r '
      (.providers // [])[] as $p | ($p.env // {}) | to_entries[] |
      "\($p.name)\t\(.key)\t\(.value)"
    ' "$STATE/config.json")
  fi
fi

# === claude CLI capability ===
section "claude CLI capability"
if claude --help 2>&1 | grep -qE -- '--effort[[:space:]]'; then
  ok "claude CLI supports --effort flag"
else
  no "claude CLI too old — no --effort flag. Upgrade to a version that supports 'low|medium|high|xhigh|max' effort levels, or remove .sorcerer/config.json:effort."
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

# === Token refresh + validity (per project: tokens scoped to project's repos' owners) ===
section "GitHub token (minted via refresh-token.sh)"
if [[ -n "$SORCERER_REPO" && -f "$SORCERER_REPO/scripts/refresh-token.sh" ]]; then
  # Try minting without a specific owner — lets the script auto-pick if count==1,
  # otherwise we just note it couldn't pick without hint.
  if TOKEN_OUT=$(GH_APP_INSTALLATION_ID= bash "$SORCERER_REPO/scripts/refresh-token.sh" 2>&1); then
    if grep -q '^export GITHUB_TOKEN=' <<<"$TOKEN_OUT"; then
      ok "refresh-token.sh minted a token"
      eval "$TOKEN_OUT"
      if installs=$(gh api /installation/repositories 2>/dev/null); then
        owner=$(jq -r '.repositories[0].owner.login // "unknown"' <<<"$installs")
        count=$(jq -r '.total_count // 0' <<<"$installs")
        ok "token authenticates ($count repo(s) accessible, currently scoped to $owner)"
      else
        no "minted token failed gh api /installation/repositories"
      fi
    else
      no "refresh-token.sh produced no GITHUB_TOKEN line"
    fi
  else
    warn "refresh-token.sh couldn't auto-pick an install (expected if App is installed on multiple accounts; sorcerer picks per-repo at runtime)"
  fi
else
  no "refresh-token.sh missing (is SORCERER_REPO correct?)"
fi

# === Per-project configuration ===
section "Project config"
REPOS=""; EXPLORABLE=""
if [[ ! -f "$STATE/config.json" ]]; then
  warn "$STATE/config.json not present — will be auto-bootstrapped on first /sorcerer invocation in this project"
else
  if jq -e . "$STATE/config.json" >/dev/null 2>&1; then
    ok "$STATE/config.json present"
    REPOS=$(jq -r '(.repos // [])[]' "$STATE/config.json")
    EXPLORABLE=$(jq -r '(.explorable_repos // [])[]' "$STATE/config.json")
  else
    no "$STATE/config.json is not valid JSON"
  fi
fi

# === Bare clones ===
# Auto-created on first use by scripts/ensure-bare-clones.sh. Missing clones
# are a NOTE (WARN) — not a failure — so the operator knows what'll be fetched.
section "Bare clones (auto-created on first use)"
if [[ -n "$EXPLORABLE" ]]; then
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    repo_no_host="${repo#github.com/}"
    bare="$STATE/repos/${repo_no_host//\//-}.git"
    if [[ -d "$bare" ]]; then
      ok "bare clone present for $repo"
    else
      warn "no bare clone yet for $repo (will auto-create on first use)"
    fi
  done <<<"$EXPLORABLE"
else
  warn "no explorable_repos yet (config.json missing or empty)"
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
  warn "skipped — need both a valid GITHUB_TOKEN and a repos list in config.json"
fi

# === Branch protection + auto-merge on each target repo ===
section "Merge gate (target repos)"
if [[ ${#REPO_INFO[@]} -gt 0 ]]; then
  for repo_no_host in "${!REPO_INFO[@]}"; do
    info="${REPO_INFO[$repo_no_host]}"
    default_branch=$(jq -r '.default_branch' <<<"$info")
    auto_merge=$(jq -r '.allow_auto_merge' <<<"$info")
    delete_branch=$(jq -r '.delete_branch_on_merge' <<<"$info")

    if branch_info=$(gh api "repos/$repo_no_host/branches/$default_branch" 2>/dev/null); then
      protected=$(jq -r '.protected' <<<"$branch_info")
      if [[ "$protected" == "true" ]]; then
        ok "$repo_no_host: branch protection on $default_branch"
      else
        no "$repo_no_host: $default_branch has NO branch protection (Settings → Branches → Add rule)"
      fi
    else
      no "$repo_no_host: cannot inspect $default_branch"
    fi

    if [[ "$auto_merge" == "true" ]]; then
      ok "$repo_no_host: auto-merge enabled"
    else
      no "$repo_no_host: auto-merge disabled (Settings → General → Pull Requests → Allow auto-merge)"
    fi

    if [[ "$delete_branch" == "true" ]]; then
      ok "$repo_no_host: head branches auto-deleted on merge"
    else
      warn "$repo_no_host: head branches not auto-deleted (cosmetic)"
    fi
  done
else
  warn "skipped — no accessible repo from config.json"
fi

# === State + space ===
section "State directory"
if [[ -d "$STATE" ]]; then
  if [[ -w "$STATE" ]]; then
    ok "$STATE writable"
  else
    no "$STATE not writable"
  fi
else
  warn "$STATE does not exist yet (will be created on first /sorcerer invocation)"
fi
avail_kb=$(df -Pk "$PROJECT_ROOT" | awk 'NR==2 {print $4}')
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
