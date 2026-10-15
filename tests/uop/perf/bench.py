# Times the same numpy-style float32 ops (elementwise add, mul, sqrt; sum over the whole vector; square matmul) with tinygrad
# (on a device chosen by argv: CPU or METAL) and with onnxruntime's CPU provider. Each timing is the median of RUNS runs after
# WARM warm-up runs; the inputs are created and synchronised before the clock starts, and each run ends with a read of one
# scalar, which is the synchronisation. Usage: bench.py tinygrad|onnxruntime [CPU|METAL]  -> JSON lines on stdout.
#
# NFCUOP_TRACE=FILE also writes a Chrome trace-event JSON file (open in https://ui.perfetto.dev), in the format of nfcxx's
# --trace (scripts/trace.sh): ph X events with name, cat, ts, dur, pid, tid and args. Each span is named "<backend> <op> n=<size>
# <phase>", with phase build (inputs for tinygrad, the session for onnxruntime), warmup, run (one timed call) and readback
# (the scalar read that synchronises tinygrad). BENCH_VEC, BENCH_MAT, BENCH_WARM and BENCH_RUNS (comma lists, or counts) shrink
# the run for tests/uop/perf/trace_test.sh.
import contextlib, json, os, statistics, sys, time

def ints(name, default): return [int(x) for x in os.environ[name].split(",")] if name in os.environ else default
WARM, RUNS = int(os.environ.get("BENCH_WARM", 3)), int(os.environ.get("BENCH_RUNS", 10))
VEC = ints("BENCH_VEC", [2**16, 2**20, 2**24])
MAT = ints("BENCH_MAT", [256, 512, 1024])

TRACE = os.environ.get("NFCUOP_TRACE")
if TRACE:
  open(TRACE, "w").write("[\n")  # closed by trace_close, so the file is valid JSON whether or not the run finishes

def now_us(): return time.time_ns() // 1000

def trace_emit(ev):
  with open(TRACE, "a") as f: f.write(json.dumps(ev) + ",\n")

@contextlib.contextmanager
def span(backend, op, n, phase):
  if not TRACE: yield; return
  name = f"{backend} {op} n={n} {phase}"
  t0 = now_us(); yield
  trace_emit({"name": name, "cat": "bench", "ph": "X", "ts": t0, "dur": now_us() - t0, "pid": os.getpid(), "tid": 1,
              "args": {"backend": backend, "op": op, "size": n, "phase": phase}})

def trace_close():  # the last event has no comma: the array must end with it
  if TRACE: open(TRACE, "a").write(json.dumps({"name": "trace_end", "ph": "i", "s": "g", "ts": now_us(), "pid": os.getpid(), "tid": 1}) + "\n]\n")

def median_ms(fn, backend, op, n):
  with span(backend, op, n, "warmup"):
    for _ in range(WARM): fn()
  ts = []
  for _ in range(RUNS):
    with span(backend, op, n, "run"):
      t0 = time.perf_counter(); fn(); ts.append((time.perf_counter() - t0) * 1e3)
  return statistics.median(ts)

def run_tinygrad(device):
  from tinygrad import Tensor, Device
  backend = f"tinygrad-{device}"
  def step(fn, op, n):  # compute the whole result and read one scalar that depends on all of it (tinygrad may slice a graph
    def go():           # that is only partly read, and its CPU kernels run asynchronously; a scalar sum forces the full compute)
      out = fn().realize()
      with span(backend, op, n, "readback"): (out if out.ndim == 0 else out.sum()).item()
    return go
  cases = []
  for n in VEC:
    with span(backend, "inputs", n, "build"):
      a = Tensor.rand(n, device=device).realize(); b = Tensor.rand(n, device=device).realize()
    for name, fn in [("add", lambda: (a + b)), ("mul", lambda: (a * b)), ("sqrt", lambda: a.sqrt()), ("sum", lambda: a.sum())]:
      cases.append((name, n, lambda fn=fn: fn().realize()))
  for n in MAT:
    with span(backend, "inputs", n, "build"):
      a = Tensor.rand(n, n, device=device).realize(); b = Tensor.rand(n, n, device=device).realize()
    cases.append(("matmul", n, lambda a=a, b=b: (a @ b).realize()))
  for name, n, fn in cases:
    ms = median_ms(step(fn, name, n), backend, name, n)
    print(json.dumps({"backend": backend, "op": name, "size": n, "ms": round(ms, 4)}), flush=True)

def run_onnxruntime():
  import numpy as np
  import onnx
  from onnx import helper, TensorProto
  import onnxruntime as ort
  backend = "onnxruntime-cpu"
  def model(op, shapes, out_shape, **kw):
    ins = [helper.make_tensor_value_info(f"x{i}", TensorProto.FLOAT, s) for i, s in enumerate(shapes)]
    out = helper.make_tensor_value_info("y", TensorProto.FLOAT, out_shape)
    node = helper.make_node(op, [f"x{i}" for i in range(len(shapes))], ["y"], **kw)
    g = helper.make_graph([node], "g", ins, [out])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 9  # the onnxruntime in use reads IR versions up to 13; onnx 1.23 writes 14
    return m.SerializeToString()
  def session(name, n, op, shapes, out_shape, **kw):
    with span(backend, name, n, "build"):  # the session creation includes graph optimisation
      return ort.InferenceSession(model(op, shapes, out_shape, **kw), providers=["CPUExecutionProvider"])
  cases = []
  rng = np.random.default_rng(0)
  for n in VEC:
    a = rng.random(n, dtype=np.float32); b = rng.random(n, dtype=np.float32)
    for name, op, ins in [("add", "Add", [a, b]), ("mul", "Mul", [a, b]), ("sqrt", "Sqrt", [a])]:
      sess = session(name, n, op, [[n]] * len(ins), [n])
      feeds = {f"x{i}": x for i, x in enumerate(ins)}
      cases.append((name, n, lambda s=sess, f=feeds: s.run(None, f)))
    sess = session("sum", n, "ReduceSum", [[n]], [], keepdims=0)
    cases.append(("sum", n, lambda s=sess, f={"x0": a}: s.run(None, f)))
  for n in MAT:
    a = rng.random((n, n), dtype=np.float32); b = rng.random((n, n), dtype=np.float32)
    sess = session("matmul", n, "MatMul", [[n, n], [n, n]], [n, n])
    cases.append(("matmul", n, lambda s=sess, f={"x0": a, "x1": b}: s.run(None, f)))
  for name, n, fn in cases:
    ms = median_ms(fn, backend, name, n)  # the outputs come back as NumPy arrays, so the read is inside the run span
    print(json.dumps({"backend": backend, "op": name, "size": n, "ms": round(ms, 4)}), flush=True)

if __name__ == "__main__":
  try:
    if sys.argv[1] == "tinygrad": run_tinygrad(sys.argv[2] if len(sys.argv) > 2 else "CPU")
    else: run_onnxruntime()
  finally:
    trace_close()
