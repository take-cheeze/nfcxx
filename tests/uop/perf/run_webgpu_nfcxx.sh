#!/usr/bin/env bash
# The benchmark's elementwise and reduction ops (add, mul, sqrt, sum) through nfcuop::np, the numpy-like API
# (gen_nfcxx_webgpu.cpp): each op is checked on WebGPU against the numpy API's own values (tests/uop/wgsl/run.html), then timed
# in headless Chrome (webgpu_bench.html). Matmul stays with gen_webgpu.py. CHROME overrides the Chrome binary (on macOS
# Chrome over Metal). Without one the WebGPU steps are skipped and only the build and the generator run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT

L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O1 -Ilib/uop "${L[@]}" tests/uop/perf/gen_nfcxx_webgpu.cpp -o "$b/gen"
"$b/gen" "$b"

if [ ! -x "$chrome" ]; then
  echo "SKIP perf/nfcxx WebGPU steps: no Chrome at \"$chrome\" (set CHROME)"
  exit 0
fi
flags=(--headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU)
[ "$(uname -s)" = Darwin ] && flags+=(--use-angle=metal)

fail=0
for op in add mul sqrt sum; do
  cp "$b/check_$op.js" "$b/case.js"
  # run.html's result is written after the GPU work, which --dump-dom does not wait for: the page logs it, and this waits for
  # that line (as the benchmark below does).
  sed 's#</body>#<script>setInterval(() => { const t = document.getElementById("result").textContent; if (t !== "pending") console.log("CHECK_RESULT " + t); }, 500);</script></body>#' \
    tests/uop/wgsl/run.html > "$b/check.html"
  "$chrome" "${flags[@]}" --enable-logging=stderr --v=0 "file://$b/check.html" 2> "$b/check_$op.log" >/dev/null &
  pid=$!
  for _ in $(seq 1 120); do grep -q CHECK_RESULT "$b/check_$op.log" 2>/dev/null && break; sleep 1; done
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  res=$(grep -o 'CHECK_RESULT .*' "$b/check_$op.log" | head -1 | sed 's/^CHECK_RESULT //; s/", source:.*//; s/ *$//')
  if [[ "$res" == PASS* ]]; then echo "ok   perf/nfcxx check $op on WebGPU: $res"
  else echo "FAIL perf/nfcxx check $op on WebGPU: ${res:-no result}"; fail=1; fi
done

cp tests/uop/perf/webgpu_bench.html "$b/"
"$chrome" "${flags[@]}" --enable-logging=stderr --v=0 "file://$b/webgpu_bench.html" 2> "$b/chrome.log" >/dev/null &
pid=$!
for _ in $(seq 1 900); do grep -q PERF_DONE "$b/chrome.log" 2>/dev/null && break; sleep 1; done
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
grep -o 'PERF[_A-Z]* .*' "$b/chrome.log" | sed 's/"$//' | sed 's/\\"/"/g'
exit $fail
