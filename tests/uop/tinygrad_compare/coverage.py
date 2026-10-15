# Which graphs that tests/uop/test_wgsl.cpp refuses does tinygrad's WGSL renderer accept? Renders each on the WebGPU
# target and prints the first line of the error, or the kernel count. Usage: coverage.py
from tinygrad import Tensor, dtypes
from tinygrad.helpers import Target
from tinygrad.codegen import to_program
from tinygrad.renderer.wgsl import WGSLRenderer
ren = WGSLRenderer(Target(device="WEBGPU", renderer="WGSL"))
def tr(label, t):
  try:
    lin = t.schedule_linear()
    n = 0
    for c in lin.src:
      to_program(c.src[0], ren); n += 1
    print(f"{label:28s} ok, {n} kernel(s)")
  except Exception as e:
    print(f"{label:28s} refused: {type(e).__name__}: {str(e).splitlines()[0][:90]}")
x = Tensor.empty(2, 3); y = Tensor.empty(2, 3); d = Tensor.empty(2, dtype=dtypes.float64)
tr("permute (movement)", x.permute(1, 0) + 0)
tr("cast to int32", x.cast(dtypes.int32) + 1)
tr("float64 add", d + d)
tr("reduce max", x.max(1))
tr("bare leaf as root", x)
tr("reduce sum (ref graph A)", ((x + y) * 2).sum(1))
tr("elementwise (ref graph B)", (x.maximum(y) - (-y)) / (x * x + 1).sqrt())
tr("reshape of input", x.reshape(3, 2) + 1)
tr("reshape + mul (static shape)", Tensor.empty(2, 3).reshape(2, 3) * 1)
