#!/usr/bin/env bash
# Set up the Shiftify dev workspace: clone (or update) the main repo, then fetch every component submodule.
# Usage: ./setup.sh [dir]   (default dir: ./shiftify)
#    or: curl -fsSL https://raw.githubusercontent.com/shiftify-rso/shiftify/main/scripts/setup.sh | bash
set -euo pipefail

REPO_URL="${SHIFTIFY_REPO:-https://github.com/shiftify-rso/shiftify.git}"
DIR="${1:-shiftify}"

command -v git >/dev/null || { echo "error: git is not installed" >&2; exit 1; }

# 1. main repo
if [ -d "$DIR/.git" ]; then
  echo "==> updating $DIR"
  git -C "$DIR" pull --ff-only
else
  echo "==> cloning $REPO_URL into $DIR"
  git clone "$REPO_URL" "$DIR"
fi

# 2. submodules: fetch, then put each on main (not detached HEAD) at its latest commit
echo "==> fetching submodules"
git -C "$DIR" submodule sync --quiet --recursive
git -C "$DIR" submodule update --init --recursive
git -C "$DIR" submodule foreach --quiet 'git checkout -q main && git pull -q --ff-only && echo "  $sm_path @ $(git log -1 --format=%h)"'

echo "==> done: $(cd "$DIR" && pwd)"
if command -v gh >/dev/null && ! gh auth status >/dev/null 2>&1; then
  echo "note: run 'gh auth login' (then 'gh auth setup-git') before pushing"
fi
