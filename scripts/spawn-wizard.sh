#!/usr/bin/env bash
# Spawn a wizard session for a given mode, in the CURRENT PROJECT.
#
# The caller's cwd is the project root; state lives under .sorcerer/ there.
# The tool itself (prompts, helper scripts) lives at $SORCERER_REPO.
#
# Usage: scripts/spawn-wizard.sh <mode> [options]
#
# Modes:
#   noop       — minimal wizard for spawn-machinery testing. No side effects.
#   architect  — Tier-1 architect (requires --request-file)
#   design     — Tier-2 designer (requires --architect-plan-file and --sub-epic-index)
#   implement  — Tier-3 issue implementation (requires --issue-meta-file)
#   feedback   — refer-back addressing (requires --issue-meta-file with pr_urls + refer_back_cycle)
#   rebase     — merge-conflict / branch-behind resolution (requires --issue-meta-file with pr_urls + conflict_cycle)
#
# Flags:
#   --request-file <path>            request markdown (required for architect)
#   --architect-plan-file <path>     architect's plan.json (required for design)
#   --sub-epic-index <int>           which sub-epic in the plan (required for design)
#   --issue-meta-file <path>         per-issue meta.json (required for implement/feedback);
#                                    its parent dir is the wizard's state_dir
#   --state-dir <path>               override the default state_dir computation
#   --model <name>                   override the default model (claude uses opus by default;
#                                    only downgrade if you've measured the role tolerates it)
#   --wizard-id <uuid>               use this UUID instead of generating one (lets
#                                    the coordinator pre-create state/<parent>/<id>/
#                                    and track sessions by a known id)
#
# Runs synchronously; returns the wizard's exit code. Callers that want
# detached execution should wrap with `nohup ... &`.
set -euo pipefail

: "${SORCERER_REPO:?SORCERER_REPO must be set}"

PROJECT_ROOT="$(pwd)"
STATE="$PROJECT_ROOT/.sorcerer"

# Source per-project token cache if available.
if [[ -f "$STATE/.token-env" ]]; then
  # shellcheck source=/dev/null
  source "$STATE/.token-env"
fi

MODE="${1:-}"
shift || true
case "$MODE" in
  noop|architect|design|implement|feedback|rebase) ;;
  *) echo "Usage: $0 <mode> [options]" >&2
     echo "Modes: noop, architect, design, implement, feedback, rebase" >&2
     exit 2 ;;
esac

REQUEST_FILE=""
MODEL=""
WIZARD_ID_OVERRIDE=""
ARCHITECT_PLAN_FILE=""
SUB_EPIC_INDEX=""
ISSUE_META_FILE=""
STATE_DIR_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --request-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --request-file requires a value" >&2; exit 2; }
      REQUEST_FILE="$2"; shift 2 ;;
    --model)
      [[ $# -ge 2 ]] || { echo "ERROR: --model requires a value" >&2; exit 2; }
      MODEL="$2"; shift 2 ;;
    --wizard-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --wizard-id requires a value" >&2; exit 2; }
      WIZARD_ID_OVERRIDE="$2"; shift 2 ;;
    --architect-plan-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --architect-plan-file requires a value" >&2; exit 2; }
      ARCHITECT_PLAN_FILE="$2"; shift 2 ;;
    --sub-epic-index)
      [[ $# -ge 2 ]] || { echo "ERROR: --sub-epic-index requires a value" >&2; exit 2; }
      SUB_EPIC_INDEX="$2"; shift 2 ;;
    --issue-meta-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --issue-meta-file requires a value" >&2; exit 2; }
      ISSUE_META_FILE="$2"; shift 2 ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --state-dir requires a value" >&2; exit 2; }
      STATE_DIR_OVERRIDE="$2"; shift 2 ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == "architect" ]]; then
  [[ -n "$REQUEST_FILE" ]] || { echo "ERROR: architect mode requires --request-file <path>" >&2; exit 2; }
  [[ -f "$REQUEST_FILE" ]] || { echo "ERROR: request file not found: $REQUEST_FILE" >&2; exit 2; }
fi

if [[ "$MODE" == "design" ]]; then
  [[ -n "$ARCHITECT_PLAN_FILE" ]] || { echo "ERROR: design mode requires --architect-plan-file <path>" >&2; exit 2; }
  [[ -f "$ARCHITECT_PLAN_FILE" ]] || { echo "ERROR: architect plan file not found: $ARCHITECT_PLAN_FILE" >&2; exit 2; }
  [[ -n "$SUB_EPIC_INDEX" ]] || { echo "ERROR: design mode requires --sub-epic-index <int>" >&2; exit 2; }
fi

if [[ "$MODE" == "implement" || "$MODE" == "feedback" || "$MODE" == "rebase" ]]; then
  [[ -n "$ISSUE_META_FILE" ]] || { echo "ERROR: $MODE mode requires --issue-meta-file <path>" >&2; exit 2; }
  [[ -f "$ISSUE_META_FILE" ]] || { echo "ERROR: issue meta file not found: $ISSUE_META_FILE" >&2; exit 2; }
  if [[ -z "$STATE_DIR_OVERRIDE" ]]; then
    STATE_DIR_OVERRIDE="$(cd "$(dirname "$ISSUE_META_FILE")" && pwd)"
  fi
fi

command -v jq       >/dev/null 2>&1 || { echo "ERROR: jq required"       >&2; exit 1; }
command -v uuidgen  >/dev/null 2>&1 || { echo "ERROR: uuidgen required"  >&2; exit 1; }
command -v claude   >/dev/null 2>&1 || { echo "ERROR: claude CLI required" >&2; exit 1; }

if [[ -n "$WIZARD_ID_OVERRIDE" ]]; then
  WIZARD_ID="$WIZARD_ID_OVERRIDE"
else
  WIZARD_ID="$(uuidgen)"
fi

if [[ -n "$STATE_DIR_OVERRIDE" ]]; then
  STATE_DIR="$STATE_DIR_OVERRIDE"
else
  case "$MODE" in
    architect) PARENT="architects" ;;
    *)         PARENT="wizards" ;;
  esac
  STATE_DIR="$STATE/$PARENT/$WIZARD_ID"
fi
mkdir -p "$STATE_DIR/logs"
mkdir -p "$STATE"

CONTEXT_FILE="$STATE_DIR/context.json"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
ESCALATION_LOG="$STATE/escalations.log"
touch "$ESCALATION_LOG"

CONFIG="${SORCERER_CONFIG:-$STATE/config.json}"
if [[ "$MODE" == "architect" || "$MODE" == "design" ]]; then
  [[ -f "$CONFIG" ]] || { echo "ERROR: $MODE mode requires config.json at $CONFIG" >&2; exit 1; }
fi

REQUEST_FILE_ABS=""
[[ -n "$REQUEST_FILE" ]] && REQUEST_FILE_ABS="$(readlink -f "$REQUEST_FILE")"

ARCHITECT_PLAN_FILE_ABS=""
[[ -n "$ARCHITECT_PLAN_FILE" ]] && ARCHITECT_PLAN_FILE_ABS="$(readlink -f "$ARCHITECT_PLAN_FILE")"

ISSUE_META_FILE_ABS=""
[[ -n "$ISSUE_META_FILE" ]] && ISSUE_META_FILE_ABS="$(readlink -f "$ISSUE_META_FILE")"

BARE_CLONES_DIR="$STATE/repos"

# --- Build context.json per mode -------------------------------------------
case "$MODE" in
  noop)
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      '{wizard_id:$wizard_id, mode:$mode, heartbeat_file:$heartbeat_file, escalation_log:$escalation_log, state_dir:$state_dir, max_refer_back_cycles:5}' \
      > "$CONTEXT_FILE"
    ;;

  architect)
    MAX_REFER=$(jq '.limits.max_refer_back_cycles // 5' "$CONFIG")
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --arg request_file "$REQUEST_FILE_ABS" \
      --arg bare_clones_dir "$BARE_CLONES_DIR" \
      --argjson max_refer_back_cycles "$MAX_REFER" \
      --slurpfile cfg "$CONFIG" \
      '{
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:$max_refer_back_cycles,
        request_file:$request_file,
        explorable_repos: ($cfg[0].explorable_repos // []),
        repos: ($cfg[0].repos // []),
        bare_clones_dir:$bare_clones_dir
      }' \
      > "$CONTEXT_FILE"
    ;;

  design)
    SUB_EPICS_LEN=$(jq '(.sub_epics // []) | length' "$ARCHITECT_PLAN_FILE")
    if (( SUB_EPIC_INDEX < 0 || SUB_EPIC_INDEX >= SUB_EPICS_LEN )); then
      echo "ERROR: sub_epic_index $SUB_EPIC_INDEX out of range (plan has $SUB_EPICS_LEN sub-epics)" >&2
      exit 1
    fi
    ARCH_DIR="$(dirname "$ARCHITECT_PLAN_FILE_ABS")"
    MAX_REFER=$(jq '.limits.max_refer_back_cycles // 5' "$CONFIG")
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --arg architect_plan_file "$ARCHITECT_PLAN_FILE_ABS" \
      --arg request_file "$ARCH_DIR/request.md" \
      --arg bare_clones_dir "$BARE_CLONES_DIR" \
      --argjson sub_epic_index "$SUB_EPIC_INDEX" \
      --argjson max_refer_back_cycles "$MAX_REFER" \
      --slurpfile plan "$ARCHITECT_PLAN_FILE" \
      '
      ($plan[0].sub_epics[$sub_epic_index]) as $se |
      {
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:$max_refer_back_cycles,
        scope: ($se.mandate // ""),
        sub_epic_name: ($se.name // "sub-epic-\($sub_epic_index)"),
        architect_plan_file:$architect_plan_file,
        request_file:$request_file,
        repos: ($se.repos // []),
        explorable_repos: ($se.explorable_repos // []),
        bare_clones_dir:$bare_clones_dir
      }' \
      > "$CONTEXT_FILE"
    ;;

  implement)
    REQUIRED='["issue_linear_id","issue_key","branch_name","default_branch","repos","worktree_paths"]'
    missing=$(jq -r --argjson req "$REQUIRED" '$req - (keys) | join(", ")' "$ISSUE_META_FILE_ABS")
    if [[ -n "$missing" ]]; then
      echo "ERROR: meta file missing required field(s): $missing" >&2
      exit 1
    fi
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --slurpfile meta "$ISSUE_META_FILE_ABS" \
      '
      {
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:5,
        issue_linear_id: $meta[0].issue_linear_id,
        issue_key:       $meta[0].issue_key,
        branch_name:     $meta[0].branch_name,
        default_branch:  $meta[0].default_branch,
        repos:           $meta[0].repos,
        worktree_paths:  $meta[0].worktree_paths
      }
      + (if $meta[0].merge_order then {merge_order: $meta[0].merge_order} else {} end)
      ' \
      > "$CONTEXT_FILE"
    ;;

  feedback)
    REQUIRED='["issue_linear_id","issue_key","branch_name","default_branch","repos","worktree_paths","pr_urls","refer_back_cycle"]'
    missing=$(jq -r --argjson req "$REQUIRED" '$req - (keys) | join(", ")' "$ISSUE_META_FILE_ABS")
    if [[ -n "$missing" ]]; then
      echo "ERROR: meta file for feedback mode missing required field(s): $missing" >&2
      exit 1
    fi
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --slurpfile meta "$ISSUE_META_FILE_ABS" \
      '
      {
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:5,
        issue_linear_id:   $meta[0].issue_linear_id,
        issue_key:         $meta[0].issue_key,
        branch_name:       $meta[0].branch_name,
        default_branch:    $meta[0].default_branch,
        repos:             $meta[0].repos,
        worktree_paths:    $meta[0].worktree_paths,
        pr_urls:           $meta[0].pr_urls,
        refer_back_cycle:  $meta[0].refer_back_cycle
      }
      + (if $meta[0].merge_order then {merge_order: $meta[0].merge_order} else {} end)
      ' \
      > "$CONTEXT_FILE"
    ;;

  rebase)
    REQUIRED='["issue_linear_id","issue_key","branch_name","default_branch","repos","worktree_paths","pr_urls","conflict_cycle"]'
    missing=$(jq -r --argjson req "$REQUIRED" '$req - (keys) | join(", ")' "$ISSUE_META_FILE_ABS")
    if [[ -n "$missing" ]]; then
      echo "ERROR: meta file for rebase mode missing required field(s): $missing" >&2
      exit 1
    fi
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --slurpfile meta "$ISSUE_META_FILE_ABS" \
      '
      {
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir,
        issue_linear_id:  $meta[0].issue_linear_id,
        issue_key:        $meta[0].issue_key,
        branch_name:      $meta[0].branch_name,
        default_branch:   $meta[0].default_branch,
        repos:            $meta[0].repos,
        worktree_paths:   $meta[0].worktree_paths,
        pr_urls:          $meta[0].pr_urls,
        conflict_cycle:   $meta[0].conflict_cycle
      }
      ' \
      > "$CONTEXT_FILE"
    ;;
esac

# For architect and design modes, ensure bare clones exist for every repo the
# wizard will read (explorable_repos ∪ repos). Implement/feedback modes read
# from pre-existing worktrees; the coordinator's tick step 9 handles their
# bare-clone creation before creating the worktree.
if [[ "$MODE" == "architect" || "$MODE" == "design" ]]; then
  REPO_LIST=$(jq -r '((.explorable_repos // []) + (.repos // [])) | unique | .[]' "$CONTEXT_FILE")
  if [[ -n "$REPO_LIST" ]]; then
    # shellcheck disable=SC2086
    bash "$SORCERER_REPO/scripts/ensure-bare-clones.sh" "$PROJECT_ROOT" $REPO_LIST
  fi
fi

case "$MODE" in
  noop)      PROMPT_FILE="$SORCERER_REPO/prompts/wizard-noop.md" ;;
  architect) PROMPT_FILE="$SORCERER_REPO/prompts/architect.md" ;;
  design)    PROMPT_FILE="$SORCERER_REPO/prompts/wizard-design.md" ;;
  implement) PROMPT_FILE="$SORCERER_REPO/prompts/wizard-implement.md" ;;
  feedback)  PROMPT_FILE="$SORCERER_REPO/prompts/wizard-feedback.md" ;;
  rebase)    PROMPT_FILE="$SORCERER_REPO/prompts/wizard-rebase.md" ;;
esac
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: missing prompt file $PROMPT_FILE" >&2; exit 1; }

LOG_FILE="$STATE_DIR/logs/spawn.txt"

echo "spawning wizard:"
echo "  id:       $WIZARD_ID"
echo "  mode:     $MODE"
echo "  state:    $STATE_DIR"
echo "  context:  $CONTEXT_FILE"
echo "  log:      $LOG_FILE"

PROMPT="$(cat "$PROMPT_FILE")"

cd "$STATE_DIR"

EXTRA_ARGS=()
[[ -n "$MODEL" ]] && EXTRA_ARGS+=(--model "$MODEL")

set +e
SORCERER_CONTEXT_FILE="$CONTEXT_FILE" \
  claude -p \
    --output-format text \
    --permission-mode bypassPermissions \
    "${EXTRA_ARGS[@]}" \
    "$PROMPT" \
  < /dev/null \
  > "$LOG_FILE" 2>&1
RC=$?
set -e

echo "  exit:     $RC"

if [[ -f "$HEARTBEAT_FILE" ]]; then
  echo "  WARN: heartbeat file still present — wizard did not exit cleanly"
else
  echo "  heartbeat removed (clean exit)"
fi

echo
echo "=== log ==="
cat "$LOG_FILE"

exit $RC
