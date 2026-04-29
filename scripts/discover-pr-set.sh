#!/usr/bin/env bash
# Discover a complete PR set on GitHub for a wizard's branch across N repos.
# Used by tick step 5c (crashed-without-output recovery) and step 11c
# (stale-heartbeat respawn recovery) to avoid marking failed when the wizard's
# durable output is already on GitHub.
#
# Usage:
#   scripts/discover-pr-set.sh <branch_name> <repo1> [<repo2> ...]
#
# Args:
#   branch_name   The wizard's branch_name (same across all its repos).
#   repos         One or more repo specs in "github.com/owner/name" form.
#
# Output: on success, prints a JSON object {"<owner/name>": "<pr_url>", ...}
# to stdout AND exits 0. On any missing PR (incomplete set), prints nothing
# and exits 1.
set -euo pipefail

BRANCH="${1:?usage: $0 <branch_name> <repo1> [<repo2> ...]}"
shift

[[ $# -ge 1 ]] || { echo "ERROR: at least one repo required" >&2; exit 2; }

json='{}'
for r in "$@"; do
  slug="${r#github.com/}"
  url=$(gh pr list --repo "$slug" --head "$BRANCH" --state open \
        --json url --jq '.[0].url // empty' 2>/dev/null)
  [[ -n "$url" ]] || exit 1
  json=$(echo "$json" | jq --arg k "$slug" --arg v "$url" '. + {($k): $v}')
done
printf '%s\n' "$json"
