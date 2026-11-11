#!/usr/bin/env bash
# WGSL rendering (lib/uop/nfcuop_wgsl.hpp): the golden text and the refusals (tests/uop/test_wgsl.cpp), then the WGSL
# modules run on WebGPU and compared with the interpreter (run.html). The WebGPU run needs a Chrome with WebGPU: on macOS
# that is Chrome over Metal (set CHROME to another path). Without one the run is skipped and only the C++ checks run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT

L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O1 -Ilib/uop "${L[@]}" tests/uop/test_wgsl.cpp -o "$b/test_wgsl" 2>/dev/null
"$b/test_wgsl" "$b"

chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
if [ ! -x "$chrome" ]; then
  echo "SKIP uop/wgsl WebGPU run: no Chrome at \"$chrome\" (set CHROME)"
  exit 0
fi
# On macOS Chrome's WebGPU runs over Metal; elsewhere the flag is left to the browser's default.
flags=(--headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU --virtual-time-budget=20000)
[ "$(uname -s)" = Darwin ] && flags+=(--use-angle=metal)

fail=0
for c in case_reduce case_elementwise; do
  cp "$b/$c.js" "$b/case.js"
  cp tests/uop/wgsl/run.html "$b/run.html"
  # The GPU readback can outlast the virtual time budget, and the DOM is then still "pending": retry that, not a FAIL.
  for try in 1 2 3; do
    res=$("$chrome" "${flags[@]}" --dump-dom "file://$b/run.html" 2>/dev/null | sed -n 's/.*<pre id="result">\([^<]*\)<\/pre>.*/\1/p')
    [ "$res" != pending ] && break
  done
  if [[ "$res" == PASS* ]]; then echo "ok   uop/wgsl $c on WebGPU: $res"
  else echo "FAIL uop/wgsl $c on WebGPU: ${res:-no result}"; fail=1; fi
done
exit $fail
