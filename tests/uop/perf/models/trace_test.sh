#!/usr/bin/env bash
# run.sh with TRACE_DIR: for every model and batch, the nfcxx C-backend trace has RUNS run spans, each with kernel spans that
# lie inside it, with positive durations, and whose sum is within the run's duration (plus a tolerance). The ONNX Runtime trace
# (onnxruntime's own profiler) has per-node events with their op type. Runs the MLP and CNN at batch 1 and 32 with 2 runs and 1
# warm-up. The tinygrad back end has no kernel-level trace here (its profiler writes its own format), so it is not checked. A missing
# onnxruntime is reported as SKIP for the ONNX Runtime trace.
cd "$(dirname "$0")/../../../.."
PY_ORT=${PY_ORT:-python3}
PY_TG=${PY_TG:-python3}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
RUNS=2
WARM=1
if ! "$PY_ORT" -I -c 'import onnx, onnxruntime, numpy' 2>/dev/null; then
  echo "SKIP models trace: onnx, onnxruntime and numpy are needed for PY_ORT ($PY_ORT)"
  exit 0
fi

MODELS_DIR="$tmp/models" TRACE_DIR="$tmp/traces" PY_ORT="$PY_ORT" PY_TG="$PY_TG" RUNS=$RUNS WARM=$WARM \
  tests/uop/perf/models/run.sh > "$tmp/run.log" 2>&1 || { echo "FAIL models run"; tail -20 "$tmp/run.log"; exit 1; }

python3 -I - "$tmp/traces" "$RUNS" <<'PY'
import glob, json, os, sys
trace_dir, runs = sys.argv[1], int(sys.argv[2])
cases = ["mlp_b1", "mlp_b32", "cnn_b1", "cnn_b32"]
for case in cases:
    path = os.path.join(trace_dir, case + ".nfcxx.trace.json")
    events = json.load(open(path))                       # fails on invalid JSON
    assert isinstance(events, list) and events, f"{case}: not a non-empty JSON array"
    for e in events:
        # a kernel with no work (RESHAPE) can measure 0 us at the clock's resolution; a run cannot
        assert e["ph"] == "X" and isinstance(e["ts"], (int, float)) and e["dur"] >= 0, (case, e)
        assert e["cat"] != "run" or e["dur"] > 0, (case, e)
        assert "pid" in e and "tid" in e and "name" in e and "args" in e, (case, e)
    run_spans = [e for e in events if e["cat"] == "run"]
    kernel_spans = [e for e in events if e["cat"] == "kernel"]
    assert len(run_spans) == runs, f"{case}: {len(run_spans)} run spans, want {runs}"
    for r in run_spans:
        ks = [k for k in kernel_spans if k["args"]["run"] == r["args"]["run"]]
        assert ks, f"{case}: run {r['args']['run']} has no kernel spans"
        end = r["ts"] + r["dur"]
        tol = max(0.02 * r["dur"], 100.0)                # microseconds: clock reads and the span bookkeeping
        for k in ks:
            assert r["ts"] - tol <= k["ts"] and k["ts"] + k["dur"] <= end + tol, (case, r, k)
        total = sum(k["dur"] for k in ks)
        assert total <= r["dur"] + tol, f"{case}: kernels sum {total} us, run {r['dur']} us"
    print(f"ok   models trace nfcxx ({case}): {len(run_spans)} run spans, {len(kernel_spans)} kernel spans")
    ort_path = os.path.join(trace_dir, case + ".ort.trace.json")
    if not os.path.exists(ort_path):
        print(f"SKIP models trace onnxruntime ({case}): no profile")
        continue
    ort = json.load(open(ort_path))
    nodes = [e for e in ort if e.get("cat") == "Node" and "op_name" in e.get("args", {})]
    assert nodes, f"{case}: onnxruntime profile has no node events with an op type"
    assert all(e["dur"] >= 0 for e in nodes), case
    print(f"ok   models trace onnxruntime ({case}): {len(nodes)} node events")
PY
status=$?
[ $status = 0 ] && exit 0 || { echo "FAIL models trace"; exit 1; }
