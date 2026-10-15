# Renders each benchmark op with tinygrad's WGSL renderer (the same path as tests/uop/tinygrad_compare/gen.py) and writes the
# kernels as one JS file for webgpu_bench.html. Usage: gen_webgpu.py OUT_JS
import json, re, sys
from tinygrad import Tensor
from tinygrad.helpers import Target
from tinygrad.codegen import to_program
from tinygrad.renderer.wgsl import WGSLRenderer
from tinygrad.uop import Ops

VEC = [2**16, 2**20, 2**24]
MAT = [256, 512, 1024]
wgsl_ren = WGSLRenderer(Target(device="WEBGPU", renderer="WGSL"))

def text(v): return v.decode() if isinstance(v, bytes) else v

def build(op, n):
  """Returns the schedule root for op at size n, with the inputs created as Tensors."""
  if op == "matmul":
    a = Tensor.empty(n, n); b = Tensor.empty(n, n); return [a, b], a @ b
  a = Tensor.empty(n); b = Tensor.empty(n)
  if op == "add": return [a, b], a + b
  if op == "mul": return [a, b], a * b
  if op == "sqrt": return [a], a.sqrt()
  if op == "sum": return [a], a.sum()
  raise ValueError(op)

def render(op, n):
  ins, root = build(op, n)
  lin = root.schedule_linear()
  names, bufs, kernels = {}, {}, []
  for i, t in enumerate(ins): names[t.uop.base] = f"in{i}"; bufs[f"in{i}"] = t.uop.base.size()[0]
  def name_of(a):
    if a.base not in names:
      names[a.base] = f"tmp{len(names)}"; bufs[names[a.base]] = a.base.size()[0]
    return names[a.base]
  for c in lin.src:
    prg = to_program(c.src[0], wgsl_ren)
    src = text([s for s in prg.src if s.op is Ops.SOURCE][0].arg)
    entry = re.search(r"@compute[^\n]*? fn (\w+)\(", src).group(1)
    sizes = {u.arg: int(u.src[0].src[0].arg) for u in prg.src[0].toposort() if u.op is Ops.SPECIAL}
    dispatch = [sizes.get(f"gidx{i}", 1) for i in range(3)]
    args = [name_of(a) for a in c.src[1:]]  # arg 0 is the kernel's output, as in gen.py
    body = src.split("fn " + entry + "(", 1)[1]
    binds = ([{"binding": 0, "uniform": True}] if "INFINITY" in body else []) + \
            [{"binding": i + 1, "buf": args[i]} for i in range(len(args)) if f"data{i}_" in body]
    kernels.append({"source": src, "entry": entry, "dispatch": dispatch, "binds": binds})
  out = names[lin.src[-1].src[1].base]
  return {"kernels": kernels, "buffers": bufs, "output": out}

cases = []
for n in VEC:
  for op in ["add", "mul", "sqrt", "sum"]:
    cases.append({"op": op, "size": n, **render(op, n)})
for n in MAT:
  cases.append({"op": "matmul", "size": n, **render("matmul", n)})
for c in cases:
  print(c["op"], c["size"], "kernels", len(c["kernels"]), "buffers", c["buffers"], file=sys.stderr)
open(sys.argv[1], "w").write("window.BENCH_CASES = " + json.dumps(cases) + ";\n")
