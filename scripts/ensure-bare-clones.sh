#!/usr/bin/env bash
# Ensure a bare clone exists for each provided repo spec.
#
# Usage: scripts/ensure-bare-clones.sh github.com/<owner>/<repo> [github.com/<owner>/<repo> ...]
#
# For each spec, if the bare clone at repos/<owner>-<repo>.git is missing,
# clones it. Atomic (clones to .tmp, renames on success). The sorcerer GitHub
# App token is auto-minted per owner — each repo's install provides the right
# scoped token — so multiple repos across multiple orgs Just Work.
#
# Idempotent. If a clone already exists, this is a no-op for that spec.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p repos

# Source the coordinator's token cache if available (bypasses per-call minting
# when a token is already in flight).
if [[ -f "$REPO_ROOT/state/.token-env" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/state/.token-env"
fi

# Cache tokens by owner so we don't re-mint on every repo.
declare -A OWNER_TOKEN

for spec in "$@"; do
  slug="${spec#github.com/}"                    # e.g. etherpilot-ai/archer
  owner="${slug%/*}"                            # e.g. etherpilot-ai
  target_name="${slug//\//-}.git"               # etherpilot-ai-archer.git
  target="$REPO_ROOT/repos/$target_name"

  if [[ -d "$target" ]]; then
    continue
  fi

  # Mint a token for this specific owner's installation. Cached across specs
  # with the same owner.
  if [[ -z "${OWNER_TOKEN[$owner]:-}" ]]; then
    # Explicitly unset any pre-existing INSTALLATION_ID so the owner filter takes effect.
    if ! out=$(GH_APP_INSTALLATION_ID= bash "$REPO_ROOT/scripts/refresh-token.sh" --installation-owner "$owner" 2>&1); then
      cat >&2 <<EOF
ERROR: could not mint a GitHub token for owner '$owner'.

This usually means the sorcerer GitHub App is not installed on $owner.
Install it at: https://github.com/apps/sorcerer-b3k/installations
(or whatever your App's install URL is), grant access to $slug and any
other repos sorcerer should touch, then re-run.
EOF
      exit 1
    fi
    # out contains `export GITHUB_TOKEN=...` plus a couple other lines; eval to pick them up here.
    eval "$out"
    OWNER_TOKEN[$owner]="$GITHUB_TOKEN"
  fi

  tok="${OWNER_TOKEN[$owner]}"
  echo "cloning $spec → $target (bare)"

  # Atomic: clone to .tmp, scrub token from remote URL, mv into place.
  rm -rf "${target}.tmp"
  git clone --bare \
    "https://x-access-token:${tok}@github.com/${slug}.git" \
    "${target}.tmp"

  git -C "${target}.tmp" remote set-url origin "https://github.com/${slug}.git"
  mv "${target}.tmp" "$target"
  echo "  done: $target"
done
