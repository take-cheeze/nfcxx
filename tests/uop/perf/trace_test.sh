#!/usr/bin/env bash
# bench.py with NFCUOP_TRACE: the trace file is a valid Chrome trace-event array, with build, warmup, run and readback spans
# named for the backend, op and size. Runs a small configuration, so it takes seconds. Prints SKIP for a backend whose Python
# packages are missing: onnxruntime needs numpy, onnx and onnxruntime (ORT_PY, default python3); tinygrad needs tinygrad
# (TG_PY, default python3).
cd "$(dirname "$0")/../../.."
ort_py=${ORT_PY:-python3}
tg_py=${TG_PY:-python3}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # trace file, backend, op, size, stdout-lines
  python3 -I - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, backend, op, size, lines = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
events = json.load(open(path))                       # fails on invalid JSON
assert isinstance(events, list) and events, "not a non-empty JSON array"
spans = [e for e in events if e.get("ph") == "X"]
for e in spans:
    assert isinstance(e["ts"], int) and isinstance(e["dur"], int) and e["dur"] >= 0, e
    assert "pid" in e and "tid" in e and "name" in e, e
names = {e["name"] for e in spans}
for phase in ["warmup", "run"] + (["readback"] if backend.startswith("tinygrad") else []):
    want = f"{backend} {op} n={size} {phase}"
    assert any(n == want for n in names), f"missing span: {want}"
# build is the session for onnxruntime (named for the op) and the input tensors for tinygrad (named "inputs")
assert any(n in (f"{backend} {op} n={size} build", f"{backend} inputs n={size} build") for n in names), "missing build span"
runs = [e for e in spans if e["name"] == f"{backend} {op} n={size} run"]
assert len(runs) == int(__import__("os").environ["BENCH_RUNS"]), f"run spans: {len(runs)}"
assert all(e["args"]["backend"] == backend and e["args"]["op"] == op and e["args"]["size"] == int(size) for e in runs)
print(f"{len(spans)} spans, {len(runs)} run spans for {backend} {op} n={size}; {lines} result lines")
PY
}

export BENCH_VEC=65536 BENCH_MAT=64 BENCH_WARM=1 BENCH_RUNS=2

if ! "$ort_py" -I -c 'import numpy, onnx, onnxruntime' 2>/dev/null; then
  echo "SKIP bench trace (onnxruntime): numpy, onnx or onnxruntime is missing for $ort_py"
else
  NFCUOP_TRACE="$tmp/ort.json" "$ort_py" tests/uop/perf/bench.py onnxruntime > "$tmp/ort.out" || { echo "FAIL bench trace (onnxruntime)"; cat "$tmp/ort.out"; fail=1; }
  if [ "$fail" = 0 ]; then
    check "$tmp/ort.json" onnxruntime-cpu add 65536 "$(wc -l < "$tmp/ort.out" | tr -d ' ')" \
      && echo "ok   bench trace (onnxruntime)" || { echo "FAIL bench trace (onnxruntime)"; fail=1; }
  fi
fi

if ! "$tg_py" -I -c 'import tinygrad' 2>/dev/null; then
  echo "SKIP bench trace (tinygrad): tinygrad is missing for $tg_py"
else
  NFCUOP_TRACE="$tmp/tg.json" "$tg_py" tests/uop/perf/bench.py tinygrad CPU > "$tmp/tg.out" || { echo "FAIL bench trace (tinygrad)"; fail=1; }
  check "$tmp/tg.json" tinygrad-CPU add 65536 "$(wc -l < "$tmp/tg.out" | tr -d ' ')" \
    && echo "ok   bench trace (tinygrad)" || { echo "FAIL bench trace (tinygrad)"; fail=1; }
fi

exit $fail
