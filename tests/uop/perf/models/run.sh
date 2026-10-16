#!/usr/bin/env bash
# Times the real models (an MLP and a small CNN, batch 1 and 32) on onnxruntime (CPU), tinygrad (its ONNX frontend) and
# nfcxx's C backend, and checks every output against onnxruntime. Prints one JSON line per case and back end.
#
#   PY_ORT    python with onnx, onnxruntime and numpy (default: python3)
#   PY_TG     python with tinygrad 0.14 and numpy (default: python3)
#   MODELS_DIR  where the models and outputs go (default: a temporary directory, removed at exit)
#
cd "$(dirname "$0")/../../../.."
root=$PWD
PY_ORT=${PY_ORT:-python3}
PY_TG=${PY_TG:-python3}
dir=${MODELS_DIR:-$(mktemp -d)}
[ -n "${MODELS_DIR:-}" ] || trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir"
b="$dir/bench_models"
runs=${RUNS:-10}
warm=${WARM:-3}

L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp
  lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp
  lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp
  lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O2 -Ilib/uop "${L[@]}" tests/uop/perf/models/bench_models.cpp -o "$b" || { echo "FAIL build bench_models"; exit 1; }

"$PY_ORT" tests/uop/perf/models/models.py export "$dir" || { echo "FAIL export"; exit 1; }
"$PY_ORT" tests/uop/perf/models/models.py ort "$dir" "$runs" "$warm" || { echo "FAIL onnxruntime"; exit 1; }
"$PY_TG" tests/uop/perf/models/models.py tinygrad "$dir" "$runs" "$warm" || echo "tinygrad: failed (see stderr above)" >&2

for f in "$dir"/*.onnx; do
  name=$(basename "$f" .onnx)
  shape=$(cat "$dir/$name.shape")
  "$b" --onnx="$f" --input="$dir/$name.in.bin" --shape="$shape" --out="$dir/$name.nfcxx.bin" \
    --runs="$runs" --warm="$warm" > "$dir/$name.nfcxx.json" || echo "nfcxx: failed on $name" >&2
done
# The nfcxx record is the same JSON shape as the others; the compare step reads the .json files.
"$PY_ORT" tests/uop/perf/models/models.py compare "$dir"
