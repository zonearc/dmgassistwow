#!/usr/bin/env bash
# Build installable zips into dist/. Each addon folder is zipped so it unpacks
# straight into World of Warcraft/_<flavor>_/Interface/AddOns/.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check.sh
mkdir -p dist
for dir in addons/*/; do
  name=$(basename "$dir")
  version=$(sed -n 's/^## Version: *//p' "$dir/$name.toc")
  out="dist/${name}-${version}.zip"
  rm -f "$out"
  (cd addons && zip -qr "../$out" "$name")
  echo "built $out"
done
