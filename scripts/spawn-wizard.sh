#!/usr/bin/env bash
# Spawn a wizard session for a given mode.
#
# Usage: scripts/spawn-wizard.sh <mode>
#
# Modes:
#   noop       — minimal wizard for spawn-machinery testing. No side effects.
#   architect  — Tier-1 architect (reserved; not yet implemented)
#   design     — Tier-2 designer (reserved; not yet implemented)
#   implement  — issue implementation (reserved; not yet implemented)
#   feedback   — refer-back addressing (reserved; not yet implemented)
#
# Runs the wizard synchronously and returns its exit code. Callers that want
# detached execution should wrap with `nohup ... &` or equivalent — the
# coordinator owns process lifecycle, not this script.
#
# Always:
#   - generates a fresh wizard UUID
#   - creates state/wizards/<id>/ (or state/architects/<id>/ for architect mode)
#   - writes context.yaml with the standard fields documented in
#     ~/.claude/skills/wizard/SORCERER.md
#   - launches `claude -p` with SORCERER_CONTEXT_FILE pointing at it
#   - cwd of the wizard session is its state_dir
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-}"
case "$MODE" in
  noop|architect|design|implement|feedback) ;;
  *) echo "Usage: $0 <noop|architect|design|implement|feedback>" >&2; exit 2 ;;
esac

case "$MODE" in
  architect|design|implement|feedback)
    echo "ERROR: mode '$MODE' is reserved but not yet implemented" >&2
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }
command -v claude  >/dev/null 2>&1 || { echo "ERROR: claude CLI required" >&2; exit 1; }

WIZARD_ID=$(python3 -c "import uuid; print(uuid.uuid4())")

case "$MODE" in
  architect) PARENT="state/architects" ;;
  *)         PARENT="state/wizards" ;;
esac
STATE_DIR="$REPO_ROOT/$PARENT/$WIZARD_ID"
mkdir -p "$STATE_DIR/logs"
mkdir -p "$REPO_ROOT/state"

CONTEXT_FILE="$STATE_DIR/context.yaml"
HEARTBEAT_FILE="$STATE_DIR/heartbeat"
ESCALATION_LOG="$REPO_ROOT/state/escalations.log"
touch "$ESCALATION_LOG"

cat > "$CONTEXT_FILE" <<YAML
wizard_id: $WIZARD_ID
mode: $MODE
heartbeat_file: $HEARTBEAT_FILE
escalation_log: $ESCALATION_LOG
state_dir: $STATE_DIR
max_refer_back_cycles: 5
YAML

case "$MODE" in
  noop)      PROMPT_FILE="$REPO_ROOT/prompts/wizard-noop.md" ;;
  architect) PROMPT_FILE="$REPO_ROOT/prompts/architect.md" ;;
  design)    PROMPT_FILE="$REPO_ROOT/prompts/wizard-design.md" ;;
  implement) PROMPT_FILE="$REPO_ROOT/prompts/wizard-implement.md" ;;
  feedback)  PROMPT_FILE="$REPO_ROOT/prompts/wizard-feedback.md" ;;
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
set +e
# Note: we deliberately do NOT pass --add-dir. The wizard's cwd is its state_dir,
# which Claude Code makes accessible by default. Adding --add-dir here would
# greedily consume the positional prompt argument as another directory path
# and silently fast-exit. Modes that need access to additional directories
# (e.g. implement-mode wizards needing worktree paths) should use a `--`
# separator to terminate the directory list before the prompt.
#
# stdin is redirected to /dev/null so claude doesn't pause 3s waiting for
# piped input.
SORCERER_CONTEXT_FILE="$CONTEXT_FILE" \
  claude -p \
    --output-format text \
    --permission-mode bypassPermissions \
    --max-budget-usd 1 \
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
