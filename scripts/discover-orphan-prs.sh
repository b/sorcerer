#!/usr/bin/env bash
# Discover orphan PRs: open, bot-authored PRs on configured repos that no
# active_wizards entry claims. Used by tick step 11d.
#
# Usage:
#   scripts/discover-orphan-prs.sh <bot_author> [project_root]
#
# Args:
#   bot_author    GitHub login of the App identity (e.g. "sorcerer-b3k[bot]"),
#                 or "@me" if `gh` is authed as the App itself.
#   project_root  Path to project root (default: $PWD). Reads
#                 .sorcerer/sorcerer.json and .sorcerer/config.json from here.
#
# Output: zero or more JSON lines on stdout, one per orphan PR:
#   {"repo":"<owner/name>","pr_url":"...","branch":"...","head_sha":"...","issue_key":"<SOR-N|null>"}
#
# Exit: always 0. Empty stdout means no orphans this tick.
#
# Filtering: excludes wip/<uuid-prefix> WIP-preservation branches (those are
# pushed by failed-wizard preservation for audit, not for review/merge).
# Excludes any PR whose URL or branch already appears in active_wizards.
set -euo pipefail

BOT_AUTHOR="${1:?usage: $0 <bot_author> [project_root]}"
PROJECT_ROOT="${2:-$PWD}"
cd "$PROJECT_ROOT"

[[ -f .sorcerer/config.json ]] || exit 0

claimed_branches=$(jq -r '
  [(.active_wizards // [])[]
   | select(.mode | IN("implement","feedback","rebase"))
   | .branch_name // empty] | .[]
' .sorcerer/sorcerer.json 2>/dev/null | sort -u)
claimed_urls=$(jq -r '
  [(.active_wizards // [])[]
   | select(.mode | IN("implement","feedback","rebase"))
   | (.pr_urls // {}) | to_entries[] | .value] | .[]
' .sorcerer/sorcerer.json 2>/dev/null | sort -u)

repos=$(jq -r '(.repos // []) | .[]' .sorcerer/config.json)
for repo_path in $repos; do
  slug="${repo_path#github.com/}"
  gh pr list --repo "$slug" --state open --author "$BOT_AUTHOR" \
    --json url,headRefName,headRefOid \
    --jq '.[] | "\(.url)\t\(.headRefName)\t\(.headRefOid)"' 2>/dev/null \
  | while IFS=$'\t' read -r url branch sha; do
      [[ -n "$url" ]] || continue
      [[ "$branch" =~ ^wip/[0-9a-f-]{8,}$ ]] && continue
      if grep -qxF "$branch" <<<"$claimed_branches" || grep -qxF "$url" <<<"$claimed_urls"; then
        continue
      fi
      issue_key=$(printf '%s' "$branch" | grep -oiE '[A-Z]{2,5}-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
      [[ -z "$issue_key" ]] && issue_key="null"
      jq -nc \
        --arg repo "$slug" --arg url "$url" --arg branch "$branch" \
        --arg sha "$sha" --arg ik "$issue_key" \
        '{repo:$repo, pr_url:$url, branch:$branch, head_sha:$sha,
          issue_key:(if $ik=="null" then null else $ik end)}'
    done
done
