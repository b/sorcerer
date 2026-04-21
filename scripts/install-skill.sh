#!/usr/bin/env bash
# Install the /sorcerer slash command at user-level so it works from any
# Claude Code session in any directory.
#
# Strategy: symlink the project's `.claude/skills/sorcerer/` into
# `~/.claude/skills/sorcerer/`. The symlink means future updates to the
# skill in this repo are picked up automatically — no re-install needed.
#
# After install, the user must export SORCERER_REPO in their shell profile
# pointing at this repo. The skill reads that env var to locate state/,
# scripts/, and prompts/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/.claude/skills/sorcerer"
TARGET="$HOME/.claude/skills/sorcerer"

[[ -d "$SOURCE" ]] || { echo "ERROR: $SOURCE not found (is this the sorcerer repo?)" >&2; exit 1; }

mkdir -p "$HOME/.claude/skills"

if [[ -L "$TARGET" ]]; then
  current=$(readlink "$TARGET")
  if [[ "$current" == "$SOURCE" ]]; then
    echo "Already installed: $TARGET -> $SOURCE"
  else
    echo "Replacing existing symlink: $TARGET -> $current ⇒ $SOURCE"
    ln -sfn "$SOURCE" "$TARGET"
  fi
elif [[ -e "$TARGET" ]]; then
  echo "ERROR: $TARGET exists and is not a symlink. Move or remove it first." >&2
  exit 1
else
  ln -s "$SOURCE" "$TARGET"
  echo "Installed: $TARGET -> $SOURCE"
fi

echo
echo "Final step (one-time): set SORCERER_REPO in your shell profile, e.g.:"
echo "  echo 'export SORCERER_REPO=$REPO_ROOT' >> ~/.shell_env"
echo "  source ~/.shell_env"
echo
echo "Then in any Claude Code session, type:  /sorcerer <prompt>"

# Optional sanity hint: warn if SORCERER_REPO is currently unset in the
# invoking shell.
if [[ -z "${SORCERER_REPO:-}" ]]; then
  echo
  echo "Note: SORCERER_REPO is currently unset in this shell."
fi
