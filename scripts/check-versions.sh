#!/usr/bin/env bash
# All addons in this repo share one version. It lives in each .toc (## Version) and in
# each addon's Lua (ns.VERSION). This fails if any of them disagree, or (with a tag
# argument like v0.2.0) if they don't match the tag being released.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:-}"
versions=()
for toc in addons/*/*.toc; do
  v=$(sed -n 's/^## Version: *//p' "$toc" | tr -d '\r')
  versions+=("$v")
  dir=$(dirname "$toc")
  lua_v=$(grep -rhoE 'ns\.VERSION = "[^"]+"' "$dir" --include='*.lua' | head -1 | sed -E 's/.*"([^"]+)"/\1/')
  if [ -n "$lua_v" ] && [ "$lua_v" != "$v" ]; then
    echo "version mismatch in $dir: toc $v, ns.VERSION $lua_v" >&2
    exit 1
  fi
done
first="${versions[0]}"
for v in "${versions[@]}"; do
  if [ "$v" != "$first" ]; then
    echo "addons disagree on version: ${versions[*]}" >&2
    exit 1
  fi
done
if [ -n "$tag" ] && [ "v$first" != "$tag" ]; then
  echo "tag $tag does not match addon version $first (run scripts/bump-version.sh)" >&2
  exit 1
fi
echo "version $first"
