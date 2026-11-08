#!/usr/bin/env bash
# Build installable zips into dist/. Each addon folder is zipped so it unpacks straight into
# World of Warcraft/_<flavor>_/Interface/AddOns/.
#   scripts/package.sh                 zips named <Addon>-<version>.zip (version from the .toc)
#   PACKAGE_VERSION=0.1.0.42 scripts/package.sh
#                                      stamps that version into the zipped copies (## Version and ns.VERSION;
#                                      the repo itself is untouched) and also writes fixed-name <Addon>.zip
#                                      copies for stable download links (nightly builds)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check.sh
rm -rf dist
mkdir -p dist
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for dir in addons/*/; do
  name=$(basename "$dir")
  version=$(sed -n 's/^## Version: *//p' "$dir/$name.toc" | tr -d '\r')
  cp -R "$dir" "$stage/$name"
  if [ -n "${PACKAGE_VERSION:-}" ]; then
    sed -i "s/^## Version: .*/## Version: $PACKAGE_VERSION/" "$stage/$name/$name.toc"
    grep -rl 'ns.VERSION = "' "$stage/$name" --include='*.lua' | xargs -r sed -i "s/ns.VERSION = \"[^\"]*\"/ns.VERSION = \"$PACKAGE_VERSION\"/"
    version="$PACKAGE_VERSION"
  fi
  (cd "$stage" && zip -qr "$OLDPWD/dist/${name}-${version}.zip" "$name")
  if [ -n "${PACKAGE_VERSION:-}" ]; then
    cp "dist/${name}-${version}.zip" "dist/${name}.zip"
  fi
  echo "built dist/${name}-${version}.zip"
done
