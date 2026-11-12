#!/usr/bin/env bash
# CRuby 4 + YJIT runs bc2cpp on itself; nfcxx builds the emitted C++.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${BC2CPP_WORLD_ROOT:-}" ]; then
  . "$root/tests/bc2cpp/fetch.sh"
  bc2cpp_fetch >&2
  export BC2CPP_WORLD_ROOT=$bc2cpp_root
fi
git -C "$root" submodule update --init --depth 1 bc2cpp/3rd/prism bc2cpp/3rd/rbs >&2
exec "${BC2CPP_HOST_RUBY:-ruby}" --yjit "$root/bc2cpp/tools/self_compile/build.rb" "$@"
