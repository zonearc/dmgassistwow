#!/usr/bin/env bash
# Fetch SimulationCraft's generated priority lists, spell dumps and class modules (ActionPriorityLists/,
# SpellDataDump/, engine/class_modules/: the code that holds every spell interaction) for
# the branches we import. Result: <dest>/<branch>/ActionPriorityLists/...
# Usage: scripts/fetch-simc.sh [dest]   (default .libraries/simc)
set -euo pipefail
cd "$(dirname "$0")/.."
dest="${1:-.libraries/simc}"
mkdir -p "$dest"
for branch in midnight forever; do
  dir="$dest/$branch"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" sparse-checkout add engine/class_modules >/dev/null 2>&1 || true
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$branch"
    git -C "$dir" reset -q --hard FETCH_HEAD
  else
    git clone -q --depth 1 --filter=blob:none --sparse --branch "$branch" \
      https://github.com/simulationcraft/simc "$dir"
    git -C "$dir" sparse-checkout set ActionPriorityLists SpellDataDump engine/class_modules >/dev/null
  fi
  echo "$branch: $(git -C "$dir" log -1 --format='%h %cd %s' --date=short)"
done
