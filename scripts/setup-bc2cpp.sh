#!/usr/bin/env bash
# Build the baked bc2cpp command with nfcxx's C++ runtime. Its Ruby sources run as mruby bytecode;
# this is the runner, not the experimental bc2cpp-self AOT build.
# BC2CPP_RPG_DIR / BC2CPP_WORLD_ROOT: an existing world; otherwise fetch the test world's pin.
# BC2CPP_RUNNER_CXX: C++ compiler (default nfcxx); NFCXX_BACKEND: nfcxx backend (default gcc).
# BC2CPP_RUNNER_BUILD_DIR: override the build directory; BC2CPP_BUILD_JOBS: rake jobs (default 8).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${BC2CPP_WORLD_ROOT:-}" ]; then
  world=$(cd "$BC2CPP_WORLD_ROOT" && pwd)
else
  . "$root/tests/bc2cpp/fetch.sh"
  bc2cpp_fetch >&2
  world=$bc2cpp_root
fi
git -C "$root" submodule update --init --depth 1 bc2cpp/3rd/prism bc2cpp/3rd/rbs >&2
export NFCXX_BACKEND=${NFCXX_BACKEND:-gcc}
out=${BC2CPP_RUNNER_BUILD_DIR:-$root/build/bc2cpp-runner-$NFCXX_BACKEND}
mkdir -p "$out"
out=$(cd "$out" && pwd)
if command -v flock >/dev/null; then
  exec 9>"$out/.lock"
  flock 9
fi
if ! (cd "$world/3rd/mruby" && env -u LD BC2CPP_WORLD_ROOT="$world" \
  BC2CPP_RUNNER_CXX="${BC2CPP_RUNNER_CXX:-$root/nfcxx}" BC2CPP_RUNNER_OPT=1 \
  MRUBY_CONFIG="$root/bc2cpp/host-libs/mruby-bc2cpp-runner/build_config.rb" \
  MRUBY_BUILD_DIR="$out" rake -j"${BC2CPP_BUILD_JOBS:-8}" all \
  "$out/bc2cpp-runner/lib/libmruby.flags.mak") > "$out/build.log" 2>&1; then
  tail -30 "$out/build.log" >&2
  echo "setup-bc2cpp: build failed; log: $out/build.log" >&2
  exit 1
fi
printf '%s\n' "$out/bc2cpp-runner/bin/mruby"
