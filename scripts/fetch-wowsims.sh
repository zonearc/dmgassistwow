#!/usr/bin/env bash
# Fetch the WoWSims sources DMGAssist uses for WoW Forever (MIT, github.com/wowsims):
#   wowsims/forever   - the Forever simulator: rotation lists (ui/specs/<class>/<spec>/apls/*.apl.json)
#   wowsims/gamedata  - every Forever class spell, re-exported from the client per build and hotfix (spells/)
# Result: <dest>/forever/..., <dest>/gamedata/...   Usage: scripts/fetch-wowsims.sh [dest] (default .libraries/wowsims)
set -euo pipefail
cd "$(dirname "$0")/.."
dest="${1:-.libraries/wowsims}"
mkdir -p "$dest"
fetch() { # repo dir sparse-paths...
  local repo="$1" dir="$dest/$2"; shift 2
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin
    git -C "$dir" reset -q --hard FETCH_HEAD
  else
    git clone -q --depth 1 --filter=blob:none --sparse "https://github.com/$repo" "$dir"
  fi
  git -C "$dir" sparse-checkout set --no-cone "$@" >/dev/null
  echo "$repo: $(git -C "$dir" log -1 --format='%h %cd %s' --date=short)"
}
fetch wowsims/forever forever '/LICENSE' '/README.md' '/ui/specs/**/apls/*'
fetch wowsims/gamedata gamedata '/README.md' '/state.json' '/spells/**'
