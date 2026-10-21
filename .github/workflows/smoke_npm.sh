#!/usr/bin/env bash
# Installs a packed @vingy/nimver into a scratch repository, starts it, and
# commits through the hook it installs.
#
#   .github/workflows/smoke_npm.sh <path to vingy-nimver-*.tgz>

set -euo pipefail

tarball="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
# npm is a Windows program there, and does not read MSYS paths.
if command -v cygpath > /dev/null; then tarball="$(cygpath -w "$tarball")"; fi

cd "$(mktemp -d)"
git init -q
git config user.email smoke@example.com
git config user.name smoke
echo '{"name": "smoke", "private": true}' > package.json
npm install --no-audit --no-fund "$tarball"
if command -v nimver > /dev/null; then
  echo "nimver is on PATH, so the hook would run it instead of the package" >&2
  exit 1
fi
npx --no-install nimver version
# Hooks installed by 5.3.0 or earlier run this path.
node_modules/@vingy/nimver/bin/nimver.js version
npx --no-install nimver init
npx --no-install nimver install-hooks
echo smoke > smoke.txt
git add smoke.txt
if git commit -q -m "not conventional"; then
  echo "the commit-msg hook let a non-conventional message through" >&2
  exit 1
fi
git commit -q -m "feat: smoke"
