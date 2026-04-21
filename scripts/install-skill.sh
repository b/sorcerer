#!/usr/bin/env bash
# Install the /sorcerer slash command at user level and pre-approve its Bash
# invocation so it doesn't prompt the user every time.
#
# What this does (idempotent):
#   1. Symlink <repo>/.claude/skills/sorcerer into ~/.claude/skills/sorcerer.
#   2. Add a permission allow rule to ~/.claude/settings.json for the
#      sorcerer-submit.sh script the skill runs, so /sorcerer executes
#      without a per-invocation permission prompt.
#
# The user must also set SORCERER_REPO in their shell profile — the script
# reminds them at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/.claude/skills/sorcerer"
TARGET="$HOME/.claude/skills/sorcerer"
SETTINGS="$HOME/.claude/settings.json"

[[ -d "$SOURCE" ]] || { echo "ERROR: $SOURCE not found (is this the sorcerer repo?)" >&2; exit 1; }

mkdir -p "$HOME/.claude/skills"

# --- 1. Symlink the skill ---
if [[ -L "$TARGET" ]]; then
  current=$(readlink "$TARGET")
  if [[ "$current" == "$SOURCE" ]]; then
    echo "Skill already installed: $TARGET -> $SOURCE"
  else
    echo "Replacing existing symlink: $TARGET -> $current ⇒ $SOURCE"
    ln -sfn "$SOURCE" "$TARGET"
  fi
elif [[ -e "$TARGET" ]]; then
  echo "ERROR: $TARGET exists and is not a symlink. Move or remove it first." >&2
  exit 1
else
  ln -s "$SOURCE" "$TARGET"
  echo "Skill installed: $TARGET -> $SOURCE"
fi

# --- 2. Add permission allow rule to ~/.claude/settings.json ---
# The /sorcerer skill issues exactly one Bash call:
#   bash $SORCERER_REPO/scripts/sorcerer-submit.sh "<prompt>"
# The pattern must cover how Claude Code will expand that command string.
# We add two forms to be safe:
#   1. Absolute-path form (what actually runs at execution time)
#   2. $SORCERER_REPO form (what the skill body literally contains)
ABS_RULE="Bash(bash $REPO_ROOT/scripts/sorcerer-submit.sh:*)"
ENV_RULE='Bash(bash $SORCERER_REPO/scripts/sorcerer-submit.sh:*)'

python3 - "$SETTINGS" "$ABS_RULE" "$ENV_RULE" <<'PY'
import json, os, sys
path, *rules = sys.argv[1:]
settings = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except Exception as e:
        print(f"WARN: could not parse {path} ({e}); leaving it alone", file=sys.stderr)
        sys.exit(0)

perms = settings.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
changed = False
for rule in rules:
    if rule not in allow:
        allow.append(rule)
        changed = True

if changed:
    # Write atomically: tmp + rename
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.rename(tmp, path)
    print(f"Added /sorcerer allow rules to {path}")
else:
    print(f"/sorcerer allow rules already present in {path}")
PY

echo
echo "Final step (one-time): set SORCERER_REPO in your shell profile:"
echo "  echo 'export SORCERER_REPO=$REPO_ROOT' >> ~/.shell_env"
echo "  source ~/.shell_env"
echo
echo "Then in any Claude Code session:  /sorcerer <prompt>"
echo "(no permission prompts — the submit script is pre-approved)"

if [[ -z "${SORCERER_REPO:-}" ]]; then
  echo
  echo "Note: SORCERER_REPO is currently unset in this shell."
fi
