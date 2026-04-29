#!/usr/bin/env bash
# Adopt one orphan PR: synthesize the active_wizards entry, materialize a
# worktree from the bare clone at the PR head, append a pr-orphan-adopted
# event. Used by tick step 11d.
#
# Usage:
#   scripts/adopt-orphan-pr.sh <orphan_json> [project_root]
#
# Args:
#   orphan_json   One JSON line as produced by discover-orphan-prs.sh.
#                 Required keys: repo, pr_url, branch, head_sha, issue_key.
#   project_root  Path to project root (default: $PWD).
#
# Output: prints the synthesized active_wizards entry as compact JSON to
# stdout. The caller appends it to .active_wizards in sorcerer.json.
#
# Side effects:
#   - Creates .sorcerer/wizards/<wid>/{logs/,trees/<repo>/} (logs/ always;
#     trees/<repo>/ only if the bare clone is reachable and the PR head
#     fetches successfully).
#   - Writes .sorcerer/wizards/<wid>/pr_urls.json.
#   - Appends one pr-orphan-adopted line to .sorcerer/events.log.
#
# If worktree materialization fails, the entry is still written with empty
# worktree_paths; the step 12 LLM gate falls back to GitHub-API reads.
set -euo pipefail

ORPHAN_JSON="${1:?usage: $0 <orphan_json> [project_root]}"
PROJECT_ROOT="${2:-$PWD}"
cd "$PROJECT_ROOT"

repo=$(jq -r '.repo'      <<<"$ORPHAN_JSON")
branch=$(jq -r '.branch'  <<<"$ORPHAN_JSON")
sha=$(jq -r '.head_sha'   <<<"$ORPHAN_JSON")
url=$(jq -r '.pr_url'     <<<"$ORPHAN_JSON")
issue_key=$(jq -r '.issue_key // ""' <<<"$ORPHAN_JSON")

wid=$(uuidgen)
state_dir=".sorcerer/wizards/${wid}"
mkdir -p "${state_dir}/logs"

owner_repo_slug="${repo//\//-}"
bare=".sorcerer/repos/${owner_repo_slug}.git"
worktree="${state_dir}/trees/${repo}"
mkdir -p "$(dirname "$worktree")"
if [[ -d "$bare" ]]; then
  git -C "$bare" fetch -f origin "+refs/pull/${url##*/}/head:refs/sorcerer-orphan/${wid}" 2>/dev/null \
    || git -C "$bare" fetch -f origin "+${branch}:refs/sorcerer-orphan/${wid}" 2>/dev/null || true
  git -C "$bare" worktree add --detach "$worktree" "refs/sorcerer-orphan/${wid}" 2>/dev/null \
    || git -C "$bare" worktree add --detach "$worktree" "$sha" 2>/dev/null || true
fi
wt_path=""
[[ -d "$worktree/.git" || -f "$worktree/.git" ]] && wt_path="$(realpath "$worktree")"

jq -n --arg k "$repo" --arg v "$url" '{($k): $v}' > "${state_dir}/pr_urls.json"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
entry=$(jq -nc \
  --arg id "$wid" --arg started "$now" --arg ik "$issue_key" \
  --arg branch "$branch" --arg repo "$repo" --arg url "$url" \
  --arg sd "$state_dir" --arg wt "$wt_path" \
  '{
    id: $id, mode: "implement", status: "awaiting-review",
    started_at: $started, designer_id: null, issue_linear_id: null,
    issue_key: (if $ik=="" then null else $ik end),
    branch_name: $branch, repos: [$repo],
    worktree_paths: (if $wt=="" then {} else {($repo): $wt} end),
    pr_urls: {($repo): $url}, state_dir: $sd,
    review_decision: null, pid: null,
    respawn_count: 0, refer_back_cycle: 0, conflict_cycle: 0,
    retry_after: null, throttle_count: 0, orphan_adopted: true
  }')

printf '{"ts":"%s","event":"pr-orphan-adopted","id":"%s","issue_key":%s,"repo":"%s","branch":"%s","pr_url":"%s","worktree":%s}\n' \
  "$now" "$wid" \
  "$(jq -Rn --arg ik "$issue_key" 'if $ik=="" then null else $ik end')" \
  "$repo" "$branch" "$url" \
  "$(jq -Rn --arg wt "$wt_path" 'if $wt=="" then null else $wt end')" \
  >> .sorcerer/events.log

printf '%s\n' "$entry"
