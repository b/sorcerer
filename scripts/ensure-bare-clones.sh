#!/usr/bin/env bash
# Ensure a bare clone exists for each provided repo spec, under the current
# project's .sorcerer/repos/ directory.
#
# Usage: scripts/ensure-bare-clones.sh <project-root> github.com/<owner>/<repo> [github.com/<owner>/<repo> ...]
#
# Idempotent. For each spec, if the bare clone at
# <project>/.sorcerer/repos/<owner>-<repo>.git is missing, clones it
# (atomic: tmp + rename). Per-owner App token auto-minted via
# refresh-token.sh --installation-owner.
set -euo pipefail

PROJECT_ROOT="${1:?usage: $0 <project-root> <repo> [<repo> ...]}"
[[ -d "$PROJECT_ROOT" ]] || { echo "ERROR: project root not a dir: $PROJECT_ROOT" >&2; exit 1; }
shift

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

cd "$PROJECT_ROOT"
mkdir -p .sorcerer/repos

# --- Allowlist gate: refuse to clone any repo not in config.explorable_repos -
# This is the universal bottleneck for sorcerer write paths — every worktree
# that could host a push lives off a bare clone we create here. If a repo
# isn't in the allowlist, we fail closed.
CONFIG="$PROJECT_ROOT/.sorcerer/config.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG missing — cannot verify repo allowlist." >&2
  echo "       Run /sorcerer in this project to bootstrap the config, or create it by hand." >&2
  exit 1
fi

declare -A ALLOWED
while IFS= read -r r; do
  [[ -n "$r" ]] && ALLOWED["$r"]=1
done < <(jq -r '(.explorable_repos // [])[]' "$CONFIG")

if [[ ${#ALLOWED[@]} -eq 0 ]]; then
  echo "ERROR: $CONFIG has no explorable_repos." >&2
  echo "       Add at least one repo before spawning wizards." >&2
  exit 1
fi

violations=()
for spec in "$@"; do
  [[ -n "${ALLOWED[$spec]:-}" ]] || violations+=("$spec")
done
if (( ${#violations[@]} > 0 )); then
  echo "ERROR: refusing to clone repos outside the allowlist:" >&2
  for v in "${violations[@]}"; do echo "  - $v" >&2; done
  echo "       Allowed (from $CONFIG:explorable_repos):" >&2
  for a in "${!ALLOWED[@]}"; do echo "  - $a" >&2; done
  echo "       Edit config.json to add the repo if you intend to let sorcerer touch it." >&2
  exit 1
fi

# Source the per-project token cache if available.
if [[ -f ".sorcerer/.token-env" ]]; then
  # shellcheck source=/dev/null
  source ".sorcerer/.token-env"
fi

declare -A OWNER_TOKEN

for spec in "$@"; do
  slug="${spec#github.com/}"
  owner="${slug%/*}"
  target_name="${slug//\//-}.git"
  target="$PROJECT_ROOT/.sorcerer/repos/$target_name"

  if [[ -d "$target" ]]; then
    continue
  fi

  if [[ -z "${OWNER_TOKEN[$owner]:-}" ]]; then
    if ! out=$(GH_APP_INSTALLATION_ID= bash "$SORCERER_REPO/scripts/refresh-token.sh" --installation-owner "$owner" 2>&1); then
      cat >&2 <<EOF
ERROR: could not mint a GitHub token for owner '$owner'.

Likely cause: the sorcerer GitHub App is not installed on $owner. Install it
(grant access to $slug and any other repos sorcerer should touch for $owner)
then re-run.
EOF
      exit 1
    fi
    eval "$out"
    OWNER_TOKEN[$owner]="$GITHUB_TOKEN"
  fi

  tok="${OWNER_TOKEN[$owner]}"
  echo "cloning $spec → $target (bare)"

  rm -rf "${target}.tmp"
  git clone --bare \
    "https://x-access-token:${tok}@github.com/${slug}.git" \
    "${target}.tmp"
  git -C "${target}.tmp" remote set-url origin "https://github.com/${slug}.git"
  mv "${target}.tmp" "$target"
  echo "  done: $target"
done
