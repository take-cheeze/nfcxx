# Renders the two tests/uop/wgsl graphs with tinygrad's own renderers (WGSL and Metal) and writes, per graph, the
# kernels (one WGSL module each) as a case for run_tinygrad.html. Usage: gen.py OUT_DIR
import json, os, re, struct, sys
from tinygrad import Tensor
from tinygrad.helpers import Target
from tinygrad.codegen import to_program
from tinygrad.renderer.wgsl import WGSLRenderer
from tinygrad.renderer.cstyle import MetalRenderer
from tinygrad.uop import Ops

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
f32 = lambda v: struct.unpack('f', struct.pack('f', v))[0]
def inp(shape, base, step):  # the values of input() in tests/uop/test_wgsl.cpp, rounded to Float32
  n = 1
  for s in shape: n *= s
  return [f32(base + step * i) for i in range(n)]
def text(v): return v.decode() if isinstance(v, bytes) else v

def graph_reduce():
  x = Tensor.empty(2, 3); y = Tensor.empty(2, 3)
  return x, y, ((x + y) * 2).sum(1), inp((2, 3), -0.7, 0.1), inp((2, 3), 1.3, -0.2)
def graph_elementwise():
  x = Tensor.empty(2, 3); y = Tensor.empty(2, 3)
  norm = (x * x + 1).sqrt()
  return x, y, (x.maximum(y) - (-y)) / norm, inp((2, 3), -0.9, 0.35), inp((2, 3), 0.6, 0.25)

wgsl_ren = WGSLRenderer(Target(device="WEBGPU", renderer="WGSL"))
metal_ren = MetalRenderer(Target(device="METAL", arch="arm64"))
summary = {}
for name, g in [("reduce", graph_reduce), ("elementwise", graph_elementwise)]:
  x, y, root, xv, yv = g()
  lin = root.schedule_linear()
  bufs = {}          # name -> {count, input, data}
  names = {}         # BUFFER uop -> name
  kernels, wsrcs, msrcs = [], [], []
  for c in lin.src:
    ast = c.src[0]
    prg = to_program(ast, wgsl_ren)
    src = text([s for s in prg.src if s.op is Ops.SOURCE][0].arg)
    msrc = text([s for s in to_program(ast, metal_ren).src if s.op is Ops.SOURCE][0].arg)
    wsrcs.append(src); msrcs.append(msrc)
    entry = re.search(r"@compute[^\n]*? fn (\w+)\(", src).group(1)
    sizes = {u.arg: int(u.src[0].src[0].arg) for u in prg.src[0].toposort() if u.op is Ops.SPECIAL}  # CAST(CONST n)
    dispatch = [sizes.get(f"gidx{i}", 1) for i in range(3)]
    binds = []
    for k, a in enumerate(c.src[1:]):
      if a.base is x.uop.base: nm, data = "x", xv
      elif a.base is y.uop.base: nm, data = "y", yv
      else: nm, data = f"arg{k}", None
      bufs.setdefault(nm, {"count": a.base.size()[0] if a.base.op is Ops.BUFFER else 0, "input": data is not None, "data": data})
      binds.append(nm)
    kernels.append({"entry": entry, "dispatch": dispatch, "binds": binds, "src": src})
  open(f"{out}/tg_{name}.wgsl", "w").write("\n".join(wsrcs))
  open(f"{out}/tg_{name}.metal", "w").write("\n".join(msrcs))
  # tinygrad's own result on its default device (METAL on this Mac), for the numeric comparison
  cpu = Tensor(xv).reshape(2, 3); cpuy = Tensor(yv).reshape(2, 3)
  cpu_out = (((cpu + cpuy) * 2).sum(1) if name == "reduce" else
             ((cpu.maximum(cpuy) - (-cpuy)) / ((cpu * cpu + 1).sqrt()))).realize().tolist()
  summary[name] = {"kernels": kernels, "bufs": {n: {k: v for k, v in b.items() if k != "data"} for n, b in bufs.items()},
                   "inputs": {n: b["data"] for n, b in bufs.items() if b["input"]},
                   "output": "arg0", "cpu": cpu_out, "wgsl_kernel_count": len(kernels)}
  print(name, "kernels", len(kernels), "bufs", {n: b["count"] for n, b in bufs.items()}, "cpu", cpu_out)
json.dump(summary, open(f"{out}/report.json", "w"), indent=1)
