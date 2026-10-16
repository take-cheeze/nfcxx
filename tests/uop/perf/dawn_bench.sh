#!/usr/bin/env bash
# Times the numpy-API elementwise cases (bench_np's add, mul and sqrt) on Dawn's native WebGPU (Metal on macOS), with the
# same timing rule as tests/uop/perf/run_webgpu.html: pipelines built once, the inputs uploaded before the timer, then the
# median of RUNS timed runs after WARM warm-up runs, each run encoding every kernel, copying one output value to a probe
# buffer, submitting, and waiting for the probe to map. Each case's output is checked against the interpreter first.
# Matmul and sum are not timed: render_wgsl refuses their graphs (RESHAPE).
#
# Usage: DAWN_SRC=<dawn checkout> DAWN_BUILD=<dawn build dir> tests/uop/perf/dawn_bench.sh [--max-n=N] -> JSON lines on stdout.
# Setup: docs/notes/uop-perf-bench.md's Dawn section, and tests/uop/wgsl/dawn/run.sh (the Dawn build).
set -euo pipefail
cd "$(dirname "$0")/../../.."
src=${DAWN_SRC:?set DAWN_SRC to the Dawn checkout}
build=${DAWN_BUILD:?set DAWN_BUILD to the Dawn build directory}
RUNS=${RUNS:-10}
max_n=
[ "${1:-}" ] && max_n=${1#--max-n=}
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT

# bench_np (the cases, and the interpreter's reference values) and the Dawn runner.
L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp
  lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp
  lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp
  lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O2 -Ilib/uop "${L[@]}" tests/uop/perf/bench_np.cpp -o "$b/bench_np"
mkdir "$b/cases"
"$b/bench_np" --only=add --case-dir="$b/cases" ${max_n:+--max-n=$max_n} > /dev/null
"$b/bench_np" --only=mul --case-dir="$b/cases" ${max_n:+--max-n=$max_n} > /dev/null
"$b/bench_np" --only=sqrt --case-dir="$b/cases" ${max_n:+--max-n=$max_n} > /dev/null

libs=$(find "$build" -name '*.a' ! -name 'libwebgpu_dawn.a' | sort | tr '\n' ' ')
clang++ -std=c++20 -O1 -w -I "$src/src/include" -I "$build/gen/include" tests/uop/wgsl/dawn/run_dawn.cc -o "$b/run_dawn" \
  $libs $libs -framework Metal -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore \
  -framework CoreGraphics -framework Cocoa -lc++

fail=0
for spec in "$b"/cases/*.spec; do
  name=$(basename "$spec" .spec)
  # bench_np wrote the WGSL source and the spec (see write_webgpu_spec). Correctness first (the run's own PASS or FAIL
  # line), then the timed runs.
  check=$("$b/run_dawn" "$b/cases/$name.wgsl" "$spec" 2>&1 || true)
  timing=$("$b/run_dawn" "$b/cases/$name.wgsl" "$spec" "$RUNS" 2>/dev/null | sed -n 's/^TIMING //p' || true)
  status=$(printf '%s\n' "$check" | sed -En 's/^(PASS|FAIL).*/\1/p' | head -1)
  exact=$(printf '%s\n' "$check" | sed -n 's/.* exact=\([0-9]*\) .*/\1/p' | head -1)
  op=${name%_*}; n=${name##*_}
  if [ "$status" != PASS ] || [ -z "$timing" ]; then
    # A dispatch over Dawn's per-dimension workgroup limit is refused by validation: one workgroup per 64 elements along X.
    reason=${status:-NO_RESULT}
    printf '%s\n' "$check" | grep -q 'exceeds max compute workgroups' && reason=DISPATCH_LIMIT
    echo "{\"backend\": \"dawn\", \"op\": \"$op\", \"n\": $n, \"status\": \"$reason\"}"; fail=1; continue
  fi
  median=$(printf '%s' "$timing" | sed -n 's/median_ms=\([0-9.]*\).*/\1/p')
  minimum=$(printf '%s' "$timing" | sed -n 's/.*min_ms=\([0-9.]*\).*/\1/p')
  echo "{\"backend\": \"dawn\", \"op\": \"$op\", \"n\": $n, \"median_ms\": $median, \"min_ms\": $minimum, \"runs\": $RUNS, \"status\": \"PASS\", \"exact\": $exact}"
done
exit $fail
