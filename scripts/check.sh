#!/usr/bin/env bash
# Everything CI runs. Needs lua5.1 (luac5.1) and luacheck.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== syntax (luac -p)"
find addons tests -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p

echo "== luacheck"
luacheck addons tests

echo "== python tests"
python3 -m unittest discover -s tests -p 'test_*.py' -q

echo "== versions agree"
./scripts/check-versions.sh

echo "== lua tests"
for t in tests/test_*.lua; do
  lua5.1 "$t"
done
