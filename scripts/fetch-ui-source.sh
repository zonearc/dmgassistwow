#!/usr/bin/env bash
# Shallow-clone Blizzard's UI source (Gethe/wow-ui-source) for API research.
# Branches: forever (WoW Forever / Camelot) and live (Mainline / Midnight).
# Result: .libraries/wow-ui-source/<branch>  (git-ignored)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .libraries/wow-ui-source
for branch in forever live; do
  dest=".libraries/wow-ui-source/$branch"
  if [ -d "$dest/.git" ]; then
    git -C "$dest" fetch -q --depth 1 origin "$branch"
    git -C "$dest" reset -q --hard FETCH_HEAD
  else
    git clone -q --depth 1 --branch "$branch" https://github.com/Gethe/wow-ui-source "$dest"
  fi
  echo "$branch: $(git -C "$dest" log -1 --format='%cd  %s')"
done
