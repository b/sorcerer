#!/usr/bin/env bash
# Spawn a wizard session for a given mode, in the CURRENT PROJECT.
#
# The caller's cwd is the project root; state lives under .sorcerer/ there.
# The tool itself (prompts, helper scripts) lives at $SORCERER_REPO.
#
# Usage: scripts/spawn-wizard.sh <mode> [options]
#
# Modes:
#   noop              — minimal wizard for spawn-machinery testing. No side effects.
#   architect         — Tier-1 architect (requires --request-file)
#   architect-review  — reviews + edits an architect's plan.json/design.md (requires --subject-state-dir)
#   design            — Tier-2 designer (requires --architect-plan-file and --sub-epic-index)
#   design-review     — reviews + edits a designer's manifest.json/Linear issues (requires --subject-state-dir,
#                       --architect-plan-file, --sub-epic-name)
#   implement         — Tier-3 issue implementation (requires --issue-meta-file)
#   feedback          — refer-back addressing (requires --issue-meta-file with pr_urls + refer_back_cycle)
#   rebase            — merge-conflict / branch-behind resolution (requires --issue-meta-file with pr_urls + conflict_cycle)
#
# Flags:
#   --request-file <path>            request markdown (required for architect)
#   --architect-plan-file <path>     architect's plan.json (required for design)
#   --sub-epic-index <int>           which sub-epic in the plan (required for design)
#   --epic-linear-id <id>            Linear epic parent issue id (optional, design mode);
#                                    designer wizard sets parentId=<id> on every save_issue
#                                    so sub-tasks roll up under the architect's epic
#   --issue-meta-file <path>         per-issue meta.json (required for implement/feedback);
#                                    its parent dir is the wizard's state_dir
#   --state-dir <path>               override the default state_dir computation
#   --model <name>                   override config.models.<role> (claude default otherwise)
#   --effort <level>                 override config.effort.<role>; low | medium | high | xhigh | max
#   --provider <name>                override the auto-selected provider (config.providers[].name);
#                                    omit to let apply-provider-env.sh pick per primary→fallback rules
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
  noop|architect|architect-review|design|design-review|implement|feedback|rebase) ;;
  *) echo "Usage: $0 <mode> [options]" >&2
     echo "Modes: noop, architect, architect-review, design, design-review, implement, feedback, rebase" >&2
     exit 2 ;;
esac

REQUEST_FILE=""
MODEL=""
EFFORT=""
PROVIDER_OVERRIDE=""
WIZARD_ID_OVERRIDE=""
ARCHITECT_PLAN_FILE=""
SUB_EPIC_INDEX=""
SUB_EPIC_NAME=""
SUBJECT_STATE_DIR=""
SUBJECT_ID=""
ISSUE_META_FILE=""
STATE_DIR_OVERRIDE=""
EPIC_LINEAR_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --request-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --request-file requires a value" >&2; exit 2; }
      REQUEST_FILE="$2"; shift 2 ;;
    --model)
      [[ $# -ge 2 ]] || { echo "ERROR: --model requires a value" >&2; exit 2; }
      MODEL="$2"; shift 2 ;;
    --effort)
      [[ $# -ge 2 ]] || { echo "ERROR: --effort requires a value" >&2; exit 2; }
      EFFORT="$2"; shift 2 ;;
    --provider)
      [[ $# -ge 2 ]] || { echo "ERROR: --provider requires a value" >&2; exit 2; }
      PROVIDER_OVERRIDE="$2"; shift 2 ;;
    --wizard-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --wizard-id requires a value" >&2; exit 2; }
      WIZARD_ID_OVERRIDE="$2"; shift 2 ;;
    --architect-plan-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --architect-plan-file requires a value" >&2; exit 2; }
      ARCHITECT_PLAN_FILE="$2"; shift 2 ;;
    --sub-epic-index)
      [[ $# -ge 2 ]] || { echo "ERROR: --sub-epic-index requires a value" >&2; exit 2; }
      SUB_EPIC_INDEX="$2"; shift 2 ;;
    --sub-epic-name)
      [[ $# -ge 2 ]] || { echo "ERROR: --sub-epic-name requires a value" >&2; exit 2; }
      SUB_EPIC_NAME="$2"; shift 2 ;;
    --subject-state-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --subject-state-dir requires a value" >&2; exit 2; }
      SUBJECT_STATE_DIR="$2"; shift 2 ;;
    --subject-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --subject-id requires a value" >&2; exit 2; }
      SUBJECT_ID="$2"; shift 2 ;;
    --issue-meta-file)
      [[ $# -ge 2 ]] || { echo "ERROR: --issue-meta-file requires a value" >&2; exit 2; }
      ISSUE_META_FILE="$2"; shift 2 ;;
    --state-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --state-dir requires a value" >&2; exit 2; }
      STATE_DIR_OVERRIDE="$2"; shift 2 ;;
    --epic-linear-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --epic-linear-id requires a value" >&2; exit 2; }
      EPIC_LINEAR_ID="$2"; shift 2 ;;
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

if [[ "$MODE" == "architect-review" ]]; then
  [[ -n "$SUBJECT_STATE_DIR" ]] || { echo "ERROR: architect-review mode requires --subject-state-dir <path>" >&2; exit 2; }
  [[ -d "$SUBJECT_STATE_DIR" ]] || { echo "ERROR: subject state dir not found: $SUBJECT_STATE_DIR" >&2; exit 2; }
  [[ -f "$SUBJECT_STATE_DIR/plan.json" ]] || { echo "ERROR: subject is missing plan.json: $SUBJECT_STATE_DIR" >&2; exit 2; }
  [[ -n "$SUBJECT_ID" ]] || { echo "ERROR: architect-review mode requires --subject-id <uuid>" >&2; exit 2; }
fi

if [[ "$MODE" == "design-review" ]]; then
  [[ -n "$SUBJECT_STATE_DIR" ]] || { echo "ERROR: design-review mode requires --subject-state-dir <path>" >&2; exit 2; }
  [[ -d "$SUBJECT_STATE_DIR" ]] || { echo "ERROR: subject state dir not found: $SUBJECT_STATE_DIR" >&2; exit 2; }
  [[ -f "$SUBJECT_STATE_DIR/manifest.json" ]] || { echo "ERROR: subject is missing manifest.json: $SUBJECT_STATE_DIR" >&2; exit 2; }
  [[ -n "$ARCHITECT_PLAN_FILE" ]] || { echo "ERROR: design-review mode requires --architect-plan-file <path>" >&2; exit 2; }
  [[ -f "$ARCHITECT_PLAN_FILE" ]] || { echo "ERROR: architect plan file not found: $ARCHITECT_PLAN_FILE" >&2; exit 2; }
  [[ -n "$SUB_EPIC_NAME" ]] || { echo "ERROR: design-review mode requires --sub-epic-name <string>" >&2; exit 2; }
  [[ -n "$SUBJECT_ID" ]] || { echo "ERROR: design-review mode requires --subject-id <uuid>" >&2; exit 2; }
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
    # Cross-architect overlap detection (SOR-533): inject a digest of
    # other in-flight architects' plans so this architect can detect
    # sub-epic redundancy before emitting its own plan.json. Empty
    # array on first/sole architect; populated when ≥2 architects run
    # in overlapping windows. Architects 2e3ff065 and 8e4b9f06 (both
    # decomposing SOR-479) collided on 2026-05-01 and produced
    # SOR-506 + SOR-522 with overlapping mandates; SOR-522 became a
    # no-op once SOR-506 merged. This digest lets the second architect
    # see the first's plan and either defer or declare a depends_on.
    EXISTING_PLANS=$(bash "$SORCERER_REPO/scripts/list-in-flight-architect-plans.sh" \
      --exclude-id "$WIZARD_ID" "$PROJECT_ROOT" 2>/dev/null || echo '[]')
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --arg request_file "$REQUEST_FILE_ABS" \
      --arg bare_clones_dir "$BARE_CLONES_DIR" \
      --argjson max_refer_back_cycles "$MAX_REFER" \
      --argjson existing_in_flight_plans "$EXISTING_PLANS" \
      --slurpfile cfg "$CONFIG" \
      '{
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:$max_refer_back_cycles,
        request_file:$request_file,
        explorable_repos: ($cfg[0].explorable_repos // []),
        repos: ($cfg[0].repos // []),
        bare_clones_dir:$bare_clones_dir,
        existing_in_flight_plans:$existing_in_flight_plans
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
      --arg epic_linear_id "$EPIC_LINEAR_ID" \
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
        bare_clones_dir:$bare_clones_dir,
        epic_linear_id: (if $epic_linear_id == "" then null else $epic_linear_id end)
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

  architect-review)
    SUBJECT_STATE_DIR_ABS="$(cd "$SUBJECT_STATE_DIR" && pwd)"
    MAX_REFER=$(jq '.limits.max_refer_back_cycles // 5' "$CONFIG" 2>/dev/null || echo 5)
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --arg subject_id "$SUBJECT_ID" \
      --arg subject_state_dir "$SUBJECT_STATE_DIR_ABS" \
      --argjson max_refer_back_cycles "$MAX_REFER" \
      --slurpfile cfg "$CONFIG" \
      '{
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:$max_refer_back_cycles,
        subject_id:$subject_id, subject_state_dir:$subject_state_dir,
        repos:            ($cfg[0].repos            // []),
        explorable_repos: ($cfg[0].explorable_repos // [])
      }' \
      > "$CONTEXT_FILE"
    ;;

  design-review)
    SUBJECT_STATE_DIR_ABS="$(cd "$SUBJECT_STATE_DIR" && pwd)"
    MAX_REFER=$(jq '.limits.max_refer_back_cycles // 5' "$CONFIG" 2>/dev/null || echo 5)
    jq -n \
      --arg wizard_id "$WIZARD_ID" \
      --arg mode "$MODE" \
      --arg heartbeat_file "$HEARTBEAT_FILE" \
      --arg escalation_log "$ESCALATION_LOG" \
      --arg state_dir "$STATE_DIR" \
      --arg subject_id "$SUBJECT_ID" \
      --arg subject_state_dir "$SUBJECT_STATE_DIR_ABS" \
      --arg architect_plan_file "$ARCHITECT_PLAN_FILE_ABS" \
      --arg sub_epic_name "$SUB_EPIC_NAME" \
      --argjson max_refer_back_cycles "$MAX_REFER" \
      --slurpfile cfg "$CONFIG" \
      '{
        wizard_id:$wizard_id, mode:$mode,
        heartbeat_file:$heartbeat_file, escalation_log:$escalation_log,
        state_dir:$state_dir, max_refer_back_cycles:$max_refer_back_cycles,
        subject_id:$subject_id, subject_state_dir:$subject_state_dir,
        architect_plan_file:$architect_plan_file,
        sub_epic_name:$sub_epic_name,
        repos: ($cfg[0].repos // [])
      }' \
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
  noop)             PROMPT_FILE="$SORCERER_REPO/prompts/wizard-noop.md" ;;
  architect)        PROMPT_FILE="$SORCERER_REPO/prompts/architect.md" ;;
  architect-review) PROMPT_FILE="$SORCERER_REPO/prompts/wizard-architect-review.md" ;;
  design)           PROMPT_FILE="$SORCERER_REPO/prompts/wizard-design.md" ;;
  design-review)    PROMPT_FILE="$SORCERER_REPO/prompts/wizard-design-review.md" ;;
  implement)        PROMPT_FILE="$SORCERER_REPO/prompts/wizard-implement.md" ;;
  feedback)         PROMPT_FILE="$SORCERER_REPO/prompts/wizard-feedback.md" ;;
  rebase)           PROMPT_FILE="$SORCERER_REPO/prompts/wizard-rebase.md" ;;
esac
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: missing prompt file $PROMPT_FILE" >&2; exit 1; }

LOG_FILE="$STATE_DIR/logs/spawn.txt"

# Resolve per-role defaults from config.json when the caller didn't pass
# --model / --effort explicitly. Role mapping:
#   architect              → config.{models,effort}.architect
#   architect-review       → config.{models,effort}.reviewer_architect
#   design                 → config.{models,effort}.designer
#   design-review          → config.{models,effort}.reviewer_design
#   implement / feedback / rebase → config.{models,effort}.executor
#   noop                   → no role; claude defaults
case "$MODE" in
  architect)                  ROLE_KEY="architect"          ;;
  architect-review)           ROLE_KEY="reviewer_architect" ;;
  design)                     ROLE_KEY="designer"           ;;
  design-review)              ROLE_KEY="reviewer_design"    ;;
  implement|feedback|rebase)  ROLE_KEY="executor"           ;;
  *)                          ROLE_KEY=""                   ;;
esac

# Pick the active provider and export its env. A --provider flag overrides
# the auto-selection; otherwise apply-provider-env.sh picks primary→fallback.
# When no providers are configured this is a no-op.
PROVIDER_MODELS_JSON="{}"
if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  # Explicit override: just look up that provider and export its env.
  if [[ -f "$CONFIG" ]] && jq -e --arg p "$PROVIDER_OVERRIDE" '(.providers // []) | any(.name == $p)' "$CONFIG" >/dev/null 2>&1; then
    while IFS=$'\t' read -r _k _v; do
      [[ -z "$_k" ]] && continue
      if [[ "$_v" =~ ^\$\{(.+)\}$ ]]; then
        _varname="${BASH_REMATCH[1]}"
        _v="${!_varname:-}"
      fi
      export "$_k=$_v"
    done < <(jq -r --arg p "$PROVIDER_OVERRIDE" '
      (.providers // [])[] | select(.name == $p) | (.env // {}) | to_entries[] |
      "\(.key)\t\(.value)"
    ' "$CONFIG")
    PROVIDER_MODELS_JSON=$(jq -rc --arg p "$PROVIDER_OVERRIDE" '
      (.providers // [])[] | select(.name == $p) | (.models // {})
    ' "$CONFIG")
    SORCERER_ACTIVE_PROVIDER="$PROVIDER_OVERRIDE"
    echo "spawn provider: $PROVIDER_OVERRIDE (explicit --provider override)"
  else
    echo "ERROR: --provider $PROVIDER_OVERRIDE not found in $CONFIG" >&2
    exit 1
  fi
else
  # shellcheck source=/dev/null
  source "$SORCERER_REPO/scripts/apply-provider-env.sh" "$CONFIG" "$STATE/sorcerer.json"
  PROVIDER_MODELS_JSON="$SORCERER_PROVIDER_MODELS"
  [[ -n "$SORCERER_ACTIVE_PROVIDER" ]] && echo "spawn provider: $SORCERER_ACTIVE_PROVIDER"
fi

if [[ -n "$ROLE_KEY" ]]; then
  # Per-provider model override wins over top-level config.models.<role>.
  if [[ -z "$MODEL" ]]; then
    MODEL=$(echo "$PROVIDER_MODELS_JSON" | jq -r --arg k "$ROLE_KEY" '.[$k] // ""' 2>/dev/null || echo "")
  fi
  if [[ -n "$ROLE_KEY" && -f "$CONFIG" ]]; then
    if [[ -z "$MODEL" ]]; then
      MODEL=$(jq -r --arg k "$ROLE_KEY" '.models[$k] // ""' "$CONFIG" 2>/dev/null || echo "")
    fi
    if [[ -z "$EFFORT" ]]; then
      EFFORT=$(jq -r --arg k "$ROLE_KEY" '.effort[$k] // ""' "$CONFIG" 2>/dev/null || echo "")
    fi
  fi
fi

# Record the active provider so the tick's 429-detection path can mark the
# right provider as throttled (not just the wizard). Empty file is fine when
# no providers are configured — the tick treats it as "ambient auth".
if [[ -n "${SORCERER_ACTIVE_PROVIDER:-}" ]]; then
  echo "$SORCERER_ACTIVE_PROVIDER" > "$STATE_DIR/provider"
fi

echo "spawning wizard:"
echo "  id:       $WIZARD_ID"
echo "  mode:     $MODE"
echo "  state:    $STATE_DIR"
echo "  context:  $CONTEXT_FILE"
echo "  log:      $LOG_FILE"
[[ -n "$MODEL"  ]] && echo "  model:    $MODEL"
[[ -n "$EFFORT" ]] && echo "  effort:   $EFFORT"

PROMPT="$(cat "$PROMPT_FILE")"

cd "$STATE_DIR"

EXTRA_ARGS=()
[[ -n "$MODEL" ]]  && EXTRA_ARGS+=(--model  "$MODEL")
[[ -n "$EFFORT" ]] && EXTRA_ARGS+=(--effort "$EFFORT")

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
