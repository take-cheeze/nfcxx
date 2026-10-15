# Times the same numpy-style float32 ops (elementwise add, mul, sqrt; sum over the whole vector; square matmul) with tinygrad
# (on a device chosen by argv: CPU or METAL) and with onnxruntime's CPU provider. Each timing is the median of RUNS runs after
# WARM warm-up runs; the inputs are created and synchronised before the clock starts, and each run ends with a read of one
# scalar, which is the synchronisation. Usage: bench.py tinygrad|onnxruntime [CPU|METAL]  -> JSON lines on stdout.
import json, statistics, sys, time
import numpy as np

WARM, RUNS = 3, 10
VEC = [2**16, 2**20, 2**24]
MAT = [256, 512, 1024]

def median_ms(fn):
  for _ in range(WARM): fn()
  ts = []
  for _ in range(RUNS):
    t0 = time.perf_counter(); fn(); ts.append((time.perf_counter() - t0) * 1e3)
  return statistics.median(ts)

def run_tinygrad(device):
  from tinygrad import Tensor, Device
  def step(fn):  # compute the whole result and read one scalar that depends on all of it (tinygrad may slice a graph
    def go():    # that is only partly read, and its CPU kernels run asynchronously; a scalar sum forces the full compute)
      out = fn().realize()
      (out if out.ndim == 0 else out.sum()).item()
    return go
  cases = []
  for n in VEC:
    a = Tensor.rand(n, device=device).realize(); b = Tensor.rand(n, device=device).realize()
    for name, fn in [("add", lambda: (a + b)), ("mul", lambda: (a * b)), ("sqrt", lambda: a.sqrt()), ("sum", lambda: a.sum())]:
      cases.append((name, n, lambda fn=fn: fn().realize()))
  for n in MAT:
    a = Tensor.rand(n, n, device=device).realize(); b = Tensor.rand(n, n, device=device).realize()
    cases.append(("matmul", n, lambda a=a, b=b: (a @ b).realize()))
  for name, n, fn in cases:
    ms = median_ms(step(fn))
    print(json.dumps({"backend": f"tinygrad-{device}", "op": name, "size": n, "ms": round(ms, 4)}), flush=True)

def run_onnxruntime():
  import onnx
  from onnx import helper, TensorProto
  import onnxruntime as ort
  def model(op, shapes, out_shape, **kw):
    ins = [helper.make_tensor_value_info(f"x{i}", TensorProto.FLOAT, s) for i, s in enumerate(shapes)]
    out = helper.make_tensor_value_info("y", TensorProto.FLOAT, out_shape)
    node = helper.make_node(op, [f"x{i}" for i in range(len(shapes))], ["y"], **kw)
    g = helper.make_graph([node], "g", ins, [out])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)])
    m.ir_version = 9  # the onnxruntime in use reads IR versions up to 13; onnx 1.23 writes 14
    return m.SerializeToString()
  cases = []
  rng = np.random.default_rng(0)
  for n in VEC:
    a = rng.random(n, dtype=np.float32); b = rng.random(n, dtype=np.float32)
    for name, op, ins, shp in [("add", "Add", [a, b], [n]), ("mul", "Mul", [a, b], [n]), ("sqrt", "Sqrt", [a], [n])]:
      sess = ort.InferenceSession(model(op, [[n]] * len(ins), [n]), providers=["CPUExecutionProvider"])
      feeds = {f"x{i}": x for i, x in enumerate(ins)}
      cases.append((name, n, lambda s=sess, f=feeds: s.run(None, f)))
    sess = ort.InferenceSession(model("ReduceSum", [[n]], [], keepdims=0), providers=["CPUExecutionProvider"])
    cases.append(("sum", n, lambda s=sess, f={"x0": a}: s.run(None, f)))
  for n in MAT:
    a = rng.random((n, n), dtype=np.float32); b = rng.random((n, n), dtype=np.float32)
    sess = ort.InferenceSession(model("MatMul", [[n, n], [n, n]], [n, n]), providers=["CPUExecutionProvider"])
    cases.append(("matmul", n, lambda s=sess, f={"x0": a, "x1": b}: s.run(None, f)))
  for name, n, fn in cases:
    ms = median_ms(fn)
    print(json.dumps({"backend": "onnxruntime-cpu", "op": name, "size": n, "ms": round(ms, 4)}), flush=True)

if __name__ == "__main__":
  if sys.argv[1] == "tinygrad": run_tinygrad(sys.argv[2] if len(sys.argv) > 2 else "CPU")
  else: run_onnxruntime()
