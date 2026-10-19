#!/usr/bin/env bash
# Run upstream lit rather than reducing its assertions to compiler acceptance.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
src=$root/build/testsuite-snapshots/clang
out=${CLANG_SUITE_OUT:-$root/build/testsuite-snapshots/clang-native-full}
scope=${1:-all}; shift || true
mkdir -p "$out/test"
out=$(cd "$out" && pwd)
cp tests/upstream/clang-full-site.py "$out/test/lit.site.cfg.py"
export CLANG_SUITE_SOURCE=$src CLANG_SUITE_OUTPUT=$out
export LLVM_TOOLS_DIR=${LLVM_TOOLS_DIR:-/usr/lib/llvm-21/bin}
export CLANG_SUITE_TRIPLE
CLANG_SUITE_TRIPLE=$("$LLVM_TOOLS_DIR/llvm-config" --host-target)
"$LLVM_TOOLS_DIR/clang" --version > "$out/compiler.txt"
"$LLVM_TOOLS_DIR/llvm-config" --assertion-mode --targets-built --shared-mode >> "$out/compiler.txt"
target=$out/test
if [ "$scope" != all ]; then target=$out/test/$scope; mkdir -p "$target"; fi
python3 "$src/llvm/utils/lit/lit.py" -sv -j "${SUITE_JOBS:-8}" --timeout "${SUITE_TIMEOUT:-60}" \
  --output "$out/results.json" "$@" "$target"
