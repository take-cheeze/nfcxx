#!/usr/bin/env bash
# The world checkout for CI steps that run inside it (.github/workflows/ci.yml, the checks job): fetches it
# (tests/bc2cpp/fetch.sh) and prints its path. Under GitHub Actions it also sets WORLD and BC2CPP_WORLD_ROOT in
# $GITHUB_ENV: bc2cpp resolves its tree to this checkout, which the world (build/bc2cpp/) sits inside rather than
# around, so it cannot find the world by walking up (bc2cpp/tools/bc2cpp/world_root.rb).
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
bc2cpp_fetch || exit 1
[ -n "${GITHUB_ENV:-}" ] && printf 'WORLD=%s\nBC2CPP_WORLD_ROOT=%s\n' "$bc2cpp_root" "$bc2cpp_root" >> "$GITHUB_ENV"
echo "$bc2cpp_root"
