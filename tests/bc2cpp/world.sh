#!/usr/bin/env bash
# The world checkout for CI steps that run inside it (.github/workflows/bc2cpp.yml, the checks job): fetches it
# (tests/bc2cpp/fetch.sh) and prints its path. Under GitHub Actions it also sets WORLD in $GITHUB_ENV.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
bc2cpp_fetch || exit 1
[ -n "${GITHUB_ENV:-}" ] && echo "WORLD=$bc2cpp_root" >> "$GITHUB_ENV"
echo "$bc2cpp_root"
