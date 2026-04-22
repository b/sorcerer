#!/usr/bin/env bash
# /sorcerer entry point.
#
# Usage (via the /sorcerer skill, which calls this as a single Bash command):
#   /sorcerer <prompt>           →  submit a new request
#   /sorcerer stop               →  stop the coordinator for THIS project
#   /sorcerer status             →  print current sorcerer.json summary
#
# "This project" = the user's current working directory. All sorcerer state
# for the project lives under <project>/.sorcerer/ — config.json, state
# (requests/architects/wizards/logs), coordinator pid, bare clones. Sorcerer's
# TOOL itself (scripts + prompts + skill) lives at $SORCERER_REPO; that's
# where this script is installed from but NOT where work happens.
set -euo pipefail

if [[ -z "${SORCERER_REPO:-}" ]]; then
  cat >&2 <<EOF
ERROR: SORCERER_REPO env var is not set.

Set it to the absolute path of your sorcerer tool repo:
  echo 'export SORCERER_REPO=/path/to/sorcerer' >> ~/.shell_env
  source ~/.shell_env
EOF
  exit 1
fi

# Detect project root. Default: cwd. If cwd is inside a git repo, walk up to
# the repo root — that way the user can type /sorcerer from a subdirectory
# and get a .sorcerer/ at the project root.
project_root() {
  local d="$PWD"
  # If inside a git repo, use the repo root.
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return
  fi
  # Otherwise, just use cwd.
  echo "$d"
}

PROJECT_ROOT="$(project_root)"

ARG="${1:-}"

# --- Subcommand dispatch --------------------------------------------------
case "$ARG" in
  stop)
    exec bash "$SORCERER_REPO/scripts/stop-coordinator.sh" "$PROJECT_ROOT"
    ;;
  status)
    STATE_DIR="$PROJECT_ROOT/.sorcerer"
    STATE_FILE="$STATE_DIR/sorcerer.json"
    echo "=== sorcerer status for $PROJECT_ROOT ==="

    # Pending requests (files in requests/ that the coordinator hasn't picked
    # up yet). Surfacing these prominently is critical — they're the most
    # commonly-missed "already running" signal.
    pending_count=0
    if [[ -d "$STATE_DIR/requests" ]]; then
      pending_count=$(find "$STATE_DIR/requests" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l)
    fi
    echo
    echo "Pending requests (not yet picked up): $pending_count"
    if (( pending_count > 0 )); then
      while IFS= read -r f; do
        first_line=$(head -1 "$f" 2>/dev/null | head -c 100)
        printf "  - %s: %s\n" "$(basename "$f")" "$first_line"
      done < <(find "$STATE_DIR/requests" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
    fi

    if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      # Coordinator-level pause (rate-limit hold).
      paused_until=$(jq -r '.paused_until // ""' "$STATE_FILE")
      if [[ -n "$paused_until" ]]; then
        now_epoch=$(date +%s)
        pause_epoch=$(date -d "$paused_until" +%s 2>/dev/null || echo 0)
        if (( pause_epoch > now_epoch )); then
          remain=$(( pause_epoch - now_epoch ))
          echo
          echo "Coordinator paused (rate-limit hold): $remain s remaining, until $paused_until"
        fi
      fi

      # Summary counts by status, per actor type.
      echo
      echo "Architects:"
      jq -r '
        (.active_architects // [])
        | group_by(.status)
        | map({status: .[0].status, count: length})
        | (if length == 0 then "  (none)"
           else (map("  \(.count) \(.status)") | join("\n"))
           end)
      ' "$STATE_FILE"

      echo
      echo "Wizards:"
      jq -r '
        (.active_wizards // [])
        | group_by([.mode, .status])
        | map({mode: .[0].mode, status: .[0].status, count: length})
        | (if length == 0 then "  (none)"
           else (map("  \(.count) \(.mode)/\(.status)") | join("\n"))
           end)
      ' "$STATE_FILE"

      # Highlight anything in a non-terminal "still working" state so the user
      # can spot in-flight items at a glance.
      echo
      echo "In-flight (will be re-evaluated next tick):"
      jq -r '
        def nonterm: (. == "pending-architect" or . == "running"
                   or . == "throttled"
                   or . == "awaiting-tier-2"   or . == "awaiting-tier-3"
                   or . == "pending-design"    or . == "awaiting-review"
                   or . == "merging");
        def fmt_a: "  architect \(.id[0:8]) [\(.status)\(if .retry_after then " until \(.retry_after)" else "" end)] — \(.request_file // "?")";
        def fmt_w: "  \(.mode) \(.id[0:8]) [\(.status)\(if .retry_after then " until \(.retry_after)" else "" end)] — \(.issue_key // .sub_epic_name // "?")";
        ( [(.active_architects // [])[] | select(.status | nonterm) | fmt_a]
          + [(.active_wizards // [])[]   | select(.status | nonterm) | fmt_w] )
        | (if length == 0 then "  (nothing in-flight)" else join("\n") end)
      ' "$STATE_FILE"

      # Raw dump last, for anyone who wants the details.
      echo
      echo "--- sorcerer.json (full) ---"
      jq . "$STATE_FILE"
    else
      echo
      echo "No coordinator state file at $STATE_FILE."
    fi

    echo
    if [[ -f "$PROJECT_ROOT/.sorcerer/coordinator.pid" ]]; then
      pid=$(cat "$PROJECT_ROOT/.sorcerer/coordinator.pid")
      if kill -0 "$pid" 2>/dev/null; then
        echo "Coordinator running (pid $pid)"
      else
        echo "Coordinator NOT running (stale pid $pid)"
      fi
    else
      echo "Coordinator NOT running"
    fi
    exit 0
    ;;
  attach)
    exec bash "$SORCERER_REPO/scripts/sorcerer-attach.sh" "$PROJECT_ROOT"
    ;;
  log)
    EVENTS="$PROJECT_ROOT/.sorcerer/events.log"
    if [[ ! -f "$EVENTS" ]]; then
      echo "No events logged yet for $PROJECT_ROOT."
      exit 0
    fi
    bash "$SORCERER_REPO/scripts/format-event.sh" < "$EVENTS"
    exit 0
    ;;
  "")
    cat >&2 <<'EOF'
Usage:
  /sorcerer <description of the system to build or refactor>   — submit a request + attach
  /sorcerer --force <same prompt>                              — bypass the duplicate-request guard
  /sorcerer stop                                                — stop the coordinator
  /sorcerer status                                              — show current state (pending/in-flight + summary)
  /sorcerer attach                                              — reattach to a running coordinator
  /sorcerer log                                                 — print full formatted event history

Sorcerer is for ambitious work — a new service, a cross-repo refactor, a
multi-component feature. Describe the desired end state; the architect will
decompose it.
EOF
    exit 2
    ;;
esac

# --- Submit flow ----------------------------------------------------------
PROMPT="$ARG"

# Allow `/sorcerer --force <prompt>` to bypass the duplicate-detection guard
# below. Useful when an earlier attempt genuinely failed and the user wants
# a fresh run against the same wording.
FORCE=0
if [[ "$PROMPT" == --force* ]]; then
  FORCE=1
  PROMPT="${PROMPT#--force}"
  PROMPT="${PROMPT#[[:space:]]}"  # strip one leading space
fi

if [[ -z "$PROMPT" ]]; then
  echo "ERROR: empty prompt after --force flag parsing." >&2
  exit 2
fi

STATE="$PROJECT_ROOT/.sorcerer"
mkdir -p "$STATE/requests"

# --- Duplicate-submission guard -------------------------------------------
# Compute a content hash of the incoming prompt and refuse if any in-flight
# architect, wizard, or pending request file has the same hash. This is the
# common footgun: a user runs /sorcerer, the architect picks up the request,
# moves it out of requests/ into architects/<id>/request.md, and the user
# — not seeing a pending request in `status` — submits again.
#
# Skipped when --force is passed (user explicitly asking to resubmit).
if [[ "$FORCE" == "0" ]]; then
  # Normalize: strip trailing whitespace, collapse trailing newlines.
  INCOMING_HASH=$(printf '%s' "$PROMPT" | sha256sum | awk '{print $1}')

  # Gather candidate request files and their hashes.
  declare -A EXISTING_HASH
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    h=$(sha256sum < "$f" | awk '{print $1}')
    # sha256sum of file content includes trailing newline that Write adds;
    # re-hash the content without the trailing newline to match the incoming
    # prompt (which sorcerer-submit writes via printf '%s\n').
    content=$(cat "$f")
    h_stripped=$(printf '%s' "$content" | sha256sum | awk '{print $1}')
    EXISTING_HASH["$f"]="$h_stripped"
  done < <(
    find "$STATE/requests" -maxdepth 1 -name '*.md' -type f 2>/dev/null
    find "$STATE/architects" -maxdepth 2 -name 'request.md' -type f 2>/dev/null
    find "$STATE/wizards" -maxdepth 2 -name 'request.md' -type f 2>/dev/null
  )

  duplicates=()
  for f in "${!EXISTING_HASH[@]}"; do
    if [[ "${EXISTING_HASH[$f]}" == "$INCOMING_HASH" ]]; then
      # For files under architects/ or wizards/, only count as a collision
      # if the associated state entry is still in a non-terminal status.
      still_active=1
      case "$f" in
        */architects/*/request.md)
          id=$(basename "$(dirname "$f")")
          if [[ -f "$STATE/sorcerer.json" ]]; then
            status=$(jq -r --arg id "$id" '(.active_architects // [])[] | select(.id == $id) | .status' "$STATE/sorcerer.json" 2>/dev/null || echo "")
            case "$status" in
              completed|failed|archived|"") still_active=0 ;;
            esac
          fi
          ;;
        */wizards/*/request.md)
          id=$(basename "$(dirname "$f")")
          if [[ -f "$STATE/sorcerer.json" ]]; then
            status=$(jq -r --arg id "$id" '(.active_wizards // [])[] | select(.id == $id) | .status' "$STATE/sorcerer.json" 2>/dev/null || echo "")
            case "$status" in
              completed|merged|failed|archived|blocked|"") still_active=0 ;;
            esac
          fi
          ;;
      esac
      if (( still_active )); then
        duplicates+=("$f")
      fi
    fi
  done

  if (( ${#duplicates[@]} > 0 )); then
    cat >&2 <<EOF
ERROR: a duplicate request is already in-flight for this project.

Content hash of your prompt matches these existing request(s):
EOF
    for d in "${duplicates[@]}"; do echo "  - $d" >&2; done
    cat >&2 <<EOF

To see what's running:  /sorcerer status
To follow progress:     /sorcerer attach

If you intend to submit this prompt a second time anyway (e.g. because the
earlier run is stuck or you want a parallel attempt), prepend --force:
  /sorcerer --force <your prompt>

If the earlier run failed and its entry shouldn't be in-flight anymore,
fix the underlying issue first; re-submitting won't unstick it.
EOF
    exit 1
  fi
fi

# Bootstrap config.json if missing. Derive repo from git remote.
if [[ ! -f "$STATE/config.json" ]]; then
  remote_url="$(cd "$PROJECT_ROOT" && git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    cat >&2 <<EOF
ERROR: $PROJECT_ROOT has no git origin remote, so sorcerer can't auto-bootstrap
$STATE/config.json. Either (a) run this from a directory that is a git repo
with a github.com remote, or (b) create $STATE/config.json by hand (see
$SORCERER_REPO/config.json.example for the schema).
EOF
    exit 1
  fi

  # Parse git@github.com:owner/repo.git OR https://github.com/owner/repo.git
  slug="$(printf '%s\n' "$remote_url" \
    | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
  if ! [[ "$slug" =~ ^[^/]+/[^/]+$ ]]; then
    echo "ERROR: could not parse owner/repo from remote URL: $remote_url" >&2
    exit 1
  fi

  team_key="${SORCERER_DEFAULT_TEAM_KEY:-SOR}"
  jq -n \
    --arg repo "github.com/$slug" \
    --arg team_key "$team_key" \
    '{
      repos:            [$repo],
      explorable_repos: [$repo],
      linear: {
        default_team_key: $team_key,
        wizard_label:     "wizard"
      },
      models: {
        coordinator: "claude-opus-4-7",
        architect:   "claude-opus-4-7",
        designer:    "claude-opus-4-7",
        executor:    "claude-opus-4-7",
        reviewer:    "claude-opus-4-7"
      },
      architect: {
        auto_threshold: {
          min_repos:            3,
          min_issues_estimate: 12
        }
      },
      limits: {
        max_concurrent_wizards: 3,
        max_refer_back_cycles:  5
      },
      merge: {
        strategy:      "squash",
        delete_branch: true
      }
    }' > "$STATE/config.json"
  echo "Bootstrapped $STATE/config.json (repo: github.com/$slug, team: $team_key)"
  echo "Edit it to adjust — in particular add other repos if this work spans multiple."
  echo
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
FIRST_LINE="$(printf '%s' "$PROMPT" | head -1)"
SLUG="$(printf '%s' "$FIRST_LINE" | head -c 80 | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//' | head -c 60 | sed 's/-$//')"
[[ -z "$SLUG" ]] && SLUG="request"
FILE="$STATE/requests/${TS}-${SLUG}.md"
printf '%s\n' "$PROMPT" > "$FILE"

echo "Request submitted: $FILE"
bash "$SORCERER_REPO/scripts/start-coordinator.sh" "$PROJECT_ROOT"

cat <<EOF

Sorcerer will autonomously:
  1. Architect — decompose the system into sub-epics with explicit boundaries
  2. Design — turn each sub-epic into a Linear epic with concrete issues
  3. Implement — spawn wizards to work each issue across the relevant repos
  4. Review — gate every PR set against acceptance criteria, then merge

Attaching to live event stream below. Ctrl-C to detach — coordinator keeps running.
Re-attach any time with:  /sorcerer attach
Status:                   /sorcerer status
Stop:                     /sorcerer stop

EOF

# Attach to the event stream so the user sees progress in real time.
exec bash "$SORCERER_REPO/scripts/sorcerer-attach.sh" "$PROJECT_ROOT"
