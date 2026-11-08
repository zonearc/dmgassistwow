#!/usr/bin/env bash
# Set the version of every addon:  scripts/bump-version.sh 0.2.0
# Then commit, and tag with:        git tag v0.2.0 && git push --tags
set -euo pipefail
cd "$(dirname "$0")/.."
new="${1:?usage: bump-version.sh X.Y.Z}"
[[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo "not a version: $new" >&2; exit 1; }
for toc in addons/*/*.toc; do
  sed -i -E "s/^## Version: .*/## Version: $new/" "$toc"
done
grep -rlE 'ns\.VERSION = "' addons --include='*.lua' | xargs sed -i -E "s/ns\.VERSION = \"[^\"]+\"/ns.VERSION = \"$new\"/"
./scripts/check-versions.sh
