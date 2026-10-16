#!/usr/bin/env bash
# bench_np with NFCUOP_TRACE: the trace file is a valid Chrome trace-event array, and for each back end that ran, it has the
# build spans, exactly WARM warmup spans and RUNS run spans, named for the back end, op and size, with the back end in the args. Runs one small
# case (add at 2^16 elements) on every back end the Session has. A back end that is unavailable here (ONNX Runtime or tinygrad)
# is reported as SKIP, from the program's own note.
cd "$(dirname "$0")/../../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
b="$tmp/bench_np"

L=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp
  lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_arena.cpp
  lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_ort.cpp
  lib/uop/nfcuop_tinygrad.cpp lib/uop/nfcuop_wgsl.cpp)
c++ -std=c++17 -O1 -Ilib/uop "${L[@]}" tests/uop/perf/bench_np.cpp -o "$b" 2>/dev/null || { echo "FAIL bench_np build"; exit 1; }

NFCUOP_TRACE="$tmp/trace.json" "$b" --max-n=65536 --only=add > "$tmp/out.jsonl" || { echo "FAIL bench_np run"; cat "$tmp/out.jsonl"; exit 1; }

python3 -I - "$tmp/trace.json" "$tmp/out.jsonl" <<'PY'
import json, sys
trace_path, out_path = sys.argv[1], sys.argv[2]
events = json.load(open(trace_path))                        # fails on invalid JSON
assert isinstance(events, list) and events, "not a non-empty JSON array"
spans = [e for e in events if e.get("ph") == "X"]
for e in spans:
    assert isinstance(e["ts"], int) and isinstance(e["dur"], int) and e["dur"] >= 0, e
    assert "pid" in e and "tid" in e and "name" in e and "args" in e, e
results = [json.loads(line) for line in open(out_path) if line.startswith("{")]
ran = {r["backend"] for r in results if "median_ms" in r and r.get("median_ms", 0) > 0}
RUNS = 10
WARM = 2
for backend in ["interpreter", "c", "onnxruntime", "tinygrad"]:
    row = next(r for r in results if r.get("backend") == backend and r.get("op") == "add")
    if backend not in ran:
        print(f"SKIP bench_np trace ({backend}): {row.get('note', 'not run')}")
        continue
    runs = [e for e in spans if e["args"].get("backend") == backend and e["args"].get("phase") == "run"]
    assert len(runs) == RUNS, f"{backend}: {len(runs)} run spans, want {RUNS}"
    assert all(e["args"]["op"] == "add" and e["args"]["n"] == 65536 and e["name"] == "run add n=65536" for e in runs), backend
    builds = [e for e in spans if e["args"].get("backend") == backend and e["args"].get("phase") == "build"]
    warms = [e for e in spans if e["args"].get("backend") == backend and e["args"].get("phase") == "warmup"]
    assert len(warms) == WARM, f"{backend}: {len(warms)} warmup spans, want {WARM}"
    assert builds, f"{backend}: no build span"
    print(f"ok   bench_np trace ({backend}): {len(runs)} run spans, {len(warms)} warmup, {len(builds)} build span(s)")
PY
status=$?
[ $status = 0 ] && exit 0 || { echo "FAIL bench_np trace"; exit 1; }
