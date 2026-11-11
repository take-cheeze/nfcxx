#!/usr/bin/env bash
# Compares tinygrad's renderers (WGSL, Metal) with ours on the tests/uop/wgsl graphs; see docs/notes/uop-tinygrad-compare.md.
# Needs tinygrad in a venv: TG_PY=/path/to/venv/bin/python (default: python3 with tinygrad installed). The WebGPU run needs
# Chrome over Metal (CHROME to override); without it only the rendering and the coverage print run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
py=${TG_PY:-python3}
here=tests/uop/tinygrad_compare
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT
export PYTHONPATH=
L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O1 -Ilib/uop "${L[@]}" tests/uop/test_wgsl.cpp -o "$b/test_wgsl" 2>/dev/null
"$b/test_wgsl" "$b"          # writes our reference cases case_reduce.js and case_elementwise.js
"$py" "$here/gen.py" "$b/tg"
"$py" "$here/case.py" "$b/tg" "$b/tg/report.json" "$b/case_reduce.js" "$b/case_elementwise.js"
"$py" "$here/coverage.py"

chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
if [ ! -x "$chrome" ]; then echo "SKIP tinygrad WebGPU run: no Chrome at \"$chrome\" (set CHROME)"; exit 0; fi
for c in reduce elementwise; do
  mkdir -p "$b/web/$c"; cp "$b/tg/tg_case_$c.js" "$b/web/$c/case.js"; cp "$here/run_tinygrad.html" "$b/web/$c/run.html"
  for try in 1 2 3 4 5; do   # the GPU readback can outlast the virtual time budget: retry
    res=$("$chrome" --headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU --virtual-time-budget=20000 --use-angle=metal --dump-dom "file://$b/web/$c/run.html" 2>/dev/null | grep -a -o '<pre id="result">[^<]*' | sed 's/<pre id="result">//')
    [ "$res" != pending ] && break
  done
  echo "tinygrad WGSL $c on WebGPU: ${res:-no result}"
done
