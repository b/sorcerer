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
#
# Flags:
#   --request-file <path>            request markdown (required for architect)
#   --architect-plan-file <path>     architect's plan.yaml (required for design)
#   --sub-epic-index <int>           which sub-epic in the plan (required for design)
#   --issue-meta-file <path>         per-issue meta.yaml (required for implement/feedback);
#                                    its parent dir is the wizard's state_dir
#   --state-dir <path>               override the default state_dir computation
#   --model <name>                   override the default model (e.g. claude-sonnet-4-6)
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
  noop|architect|design|implement|feedback) ;;
  *) echo "Usage: $0 <mode> [options]" >&2
     echo "Modes: noop, architect, design, implement, feedback" >&2
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

if [[ "$MODE" == "implement" || "$MODE" == "feedback" ]]; then
  [[ -n "$ISSUE_META_FILE" ]] || { echo "ERROR: $MODE mode requires --issue-meta-file <path>" >&2; exit 2; }
  [[ -f "$ISSUE_META_FILE" ]] || { echo "ERROR: issue meta file not found: $ISSUE_META_FILE" >&2; exit 2; }
  if [[ -z "$STATE_DIR_OVERRIDE" ]]; then
    STATE_DIR_OVERRIDE="$(cd "$(dirname "$ISSUE_META_FILE")" && pwd)"
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
command -v claude  >/dev/null 2>&1 || { echo "ERROR: claude CLI required" >&2; exit 1; }

if [[ -n "$WIZARD_ID_OVERRIDE" ]]; then
  WIZARD_ID="$WIZARD_ID_OVERRIDE"
else
  WIZARD_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
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

CONTEXT_FILE="$STATE_DIR/context.yaml"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
ESCALATION_LOG="$STATE/escalations.log"
touch "$ESCALATION_LOG"

CONFIG="${SORCERER_CONFIG:-$STATE/config.yaml}"
if [[ "$MODE" == "architect" || "$MODE" == "design" ]]; then
  [[ -f "$CONFIG" ]] || { echo "ERROR: $MODE mode requires config.yaml at $CONFIG" >&2; exit 1; }
fi

REQUEST_FILE_ABS=""
[[ -n "$REQUEST_FILE" ]] && REQUEST_FILE_ABS="$(readlink -f "$REQUEST_FILE")"

ARCHITECT_PLAN_FILE_ABS=""
[[ -n "$ARCHITECT_PLAN_FILE" ]] && ARCHITECT_PLAN_FILE_ABS="$(readlink -f "$ARCHITECT_PLAN_FILE")"

ISSUE_META_FILE_ABS=""
[[ -n "$ISSUE_META_FILE" ]] && ISSUE_META_FILE_ABS="$(readlink -f "$ISSUE_META_FILE")"

BARE_CLONES_DIR="$STATE/repos"

python3 - "$MODE" "$WIZARD_ID" "$HEARTBEAT_FILE" "$ESCALATION_LOG" "$STATE_DIR" "${CONFIG:-/dev/null}" "$REQUEST_FILE_ABS" "$BARE_CLONES_DIR" "$ARCHITECT_PLAN_FILE_ABS" "$SUB_EPIC_INDEX" "$ISSUE_META_FILE_ABS" > "$CONTEXT_FILE" <<'PY'
import os, sys, yaml
mode, wizard_id, heartbeat, escalation, state_dir, config_path, request, bare_clones_dir, plan_path, sub_epic_index, meta_path = sys.argv[1:12]

ctx = {
  'wizard_id': wizard_id,
  'mode': mode,
  'heartbeat_file': heartbeat,
  'escalation_log': escalation,
  'state_dir': state_dir,
  'max_refer_back_cycles': 5,
}

if mode == 'architect':
  with open(config_path) as f:
    cfg = yaml.safe_load(f) or {}
  ctx['max_refer_back_cycles'] = cfg.get('limits', {}).get('max_refer_back_cycles', 5)
  ctx['request_file'] = request
  ctx['explorable_repos'] = cfg.get('explorable_repos') or []
  ctx['repos'] = cfg.get('repos') or []
  ctx['bare_clones_dir'] = bare_clones_dir

elif mode == 'design':
  with open(config_path) as f:
    cfg = yaml.safe_load(f) or {}
  with open(plan_path) as f:
    plan = yaml.safe_load(f) or {}
  sub_epics = plan.get('sub_epics') or []
  idx = int(sub_epic_index)
  if idx < 0 or idx >= len(sub_epics):
    sys.exit(f"ERROR: sub_epic_index {idx} out of range (plan has {len(sub_epics)} sub-epics)")
  sub_epic = sub_epics[idx]

  arch_dir = os.path.dirname(plan_path)
  ctx['max_refer_back_cycles'] = cfg.get('limits', {}).get('max_refer_back_cycles', 5)
  ctx['scope'] = sub_epic.get('mandate', '')
  ctx['sub_epic_name'] = sub_epic.get('name', f'sub-epic-{idx}')
  ctx['architect_plan_file'] = plan_path
  ctx['request_file'] = os.path.join(arch_dir, 'request.md')
  ctx['repos'] = sub_epic.get('repos') or []
  ctx['explorable_repos'] = sub_epic.get('explorable_repos') or []
  ctx['bare_clones_dir'] = bare_clones_dir

elif mode == 'implement':
  with open(meta_path) as f:
    meta = yaml.safe_load(f) or {}
  for k in ('issue_linear_id', 'issue_key', 'branch_name', 'default_branch', 'repos', 'worktree_paths'):
    if k not in meta:
      sys.exit(f"ERROR: meta file missing required field '{k}'")
    ctx[k] = meta[k]
  if 'merge_order' in meta:
    ctx['merge_order'] = meta['merge_order']

elif mode == 'feedback':
  with open(meta_path) as f:
    meta = yaml.safe_load(f) or {}
  for k in ('issue_linear_id', 'issue_key', 'branch_name', 'default_branch', 'repos', 'worktree_paths', 'pr_urls', 'refer_back_cycle'):
    if k not in meta:
      sys.exit(f"ERROR: meta file for feedback mode missing required field '{k}'")
    ctx[k] = meta[k]
  if 'merge_order' in meta:
    ctx['merge_order'] = meta['merge_order']

print(yaml.safe_dump(ctx, sort_keys=False, default_flow_style=False), end='')
PY

# For architect and design modes, ensure bare clones exist for every repo the
# wizard will read (explorable_repos ∪ repos). Implement/feedback modes read
# from pre-existing worktrees; the coordinator's tick step 9 handles their
# bare-clone creation before creating the worktree.
if [[ "$MODE" == "architect" || "$MODE" == "design" ]]; then
  REPO_LIST="$(python3 - "$CONTEXT_FILE" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    ctx = yaml.safe_load(f) or {}
repos = list((ctx.get('explorable_repos') or []))
for r in (ctx.get('repos') or []):
    if r not in repos:
        repos.append(r)
for r in repos:
    print(r)
PY
)"
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
