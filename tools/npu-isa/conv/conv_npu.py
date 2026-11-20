"""Conv on the NPU through our own MLIR -> SHAVE route, tiled over output rows and output channels.

Each launch: flat fp16 input [padded x rows for this output-row tile (cin, hp_t, wp)] [W block (cblk, cin, k, k)]
[bias block (cblk)] zero-padded to npad; output flat fp16 (cblk, ho_t, wo). One kernel build per tile shape;
weights and bias are data. Launch sizes stay at or below LIMIT (larger single launches returned garbage).

Public: run_conv(x, W, B, stride, pad) with x (cin, hin, win) fp16 -> (cout, ho, wo) float32.
"""
import os
import shutil
import subprocess
import tempfile

import numpy as np
import onnx
from onnx import helper, TensorProto

GEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen")  # build scripts shipped next to this module
OV = os.path.expanduser("~/openvino_git/bin/intel64/Release")
ENV = dict(os.environ, LD_LIBRARY_PATH=os.path.expanduser("~/ze-loader/lib") + ":" + OV)
CACHE = os.path.expanduser("~/conv-npu-cache")
LIMIT = 262144
CARRIER_OP = "Abs"
os.makedirs(CACHE, exist_ok=True)


def divisors_desc(n):
    return [d for d in range(n, 0, -1) if n % d == 0]


def plan(cin, cout, k, wp, stride, ho, wo):
    """Pick the output-row tile ho_t (divides ho) and channel block cblk (divides cout) that keep the launch small."""
    for ho_t in divisors_desc(ho):
        hp_t = (ho_t - 1) * stride + k
        for cblk in divisors_desc(cout):
            nx = cin * hp_t * wp
            nw = cblk * cin * k * k
            nb = cblk
            nout = cblk * ho_t * wo
            npad = max(nx + nw + nb, nout)
            if npad <= LIMIT:
                return ho_t, hp_t, cblk, nx, nw, nb, nout, npad
    raise RuntimeError("no tile fits for cin=%d cout=%d k=%d wp=%d stride=%d" % (cin, cout, k, wp, stride))


def mlir_kernel(cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad):
    nx = cin * hp_t * wp
    wb = nx
    bb = nx + cblk * cin * k * k
    nout = cblk * ho_t * wo
    L = []

    def W(s):
        L.append(s)

    W("module @ConvTile {")
    W("  VPURT.SW.Runtime entryPoint : @VPU.SW::@runtime stack_configuration : [4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096, 4096]")
    W("  module @VPU.SW {")
    W('    func.func nested @runtime() attributes {VPU.kernel_code = "nnActEntry"}')
    W("    func.func @generated_0(%%arg0: memref<1x1x1x%dxf16>, %%arg1: memref<1x1x1x%dxf16>) -> memref<1x1x1x%dxf16> {" % (npad, nout, nout))
    ind = "      "
    W(ind + "affine.for %%o = 0 to %d {" % cblk)
    ind += "  "
    W(ind + "affine.for %%oh = 0 to %d {" % ho_t)
    ind += "  "
    W(ind + "affine.for %%ow = 0 to %d {" % wo)
    ind += "  "
    W(ind + "%c0 = arith.constant 0.0 : f32")
    W(ind + "%%s0 = affine.for %%i = 0 to %d iter_args(%%a0 = %%c0) -> (f32) {" % cin)
    ind += "  "
    W(ind + "%%s1 = affine.for %%kh = 0 to %d iter_args(%%a1 = %%a0) -> (f32) {" % k)
    ind += "  "
    W(ind + "%%s2 = affine.for %%kw = 0 to %d iter_args(%%a2 = %%a1) -> (f32) {" % k)
    ind += "  "
    W(ind + "%%xi = affine.load %%arg0[0, 0, 0, %%i * %d + (%%oh * %d + %%kh) * %d + %%ow * %d + %%kw] : memref<1x1x1x%dxf16>"
      % (hp_t * wp, stride, wp, stride, npad))
    W(ind + "%%wi = affine.load %%arg0[0, 0, 0, %d + %%o * %d + %%i * %d + %%kh * %d + %%kw] : memref<1x1x1x%dxf16>"
      % (wb, cin * k * k, k * k, k, npad))
    W(ind + "%%xf = arith.extf %%xi : f16 to f32")
    W(ind + "%%wf = arith.extf %%wi : f16 to f32")
    W(ind + "%%p = arith.mulf %%xf, %%wf : f32")
    W(ind + "%%n = arith.addf %%a2, %%p : f32")
    W(ind + "affine.yield %%n : f32")
    ind = ind[:-2]
    W(ind + "}")
    W(ind + "affine.yield %%s2 : f32")
    ind = ind[:-2]
    W(ind + "}")
    W(ind + "affine.yield %%s1 : f32")
    ind = ind[:-2]
    W(ind + "}")
    W(ind + "%%bi = affine.load %%arg0[0, 0, 0, %d + %%o] : memref<1x1x1x%dxf16>" % (bb, npad))
    W(ind + "%%bf = arith.extf %%bi : f16 to f32")
    W(ind + "%%yv = arith.addf %%s0, %%bf : f32")
    W(ind + "%%yh = arith.truncf %%yv : f32 to f16")
    W(ind + "affine.store %%yh, %%arg1[0, 0, 0, %%o * %d + %%oh * %d + %%ow] : memref<1x1x1x%dxf16>" % (ho_t * wo, wo, nout))
    for _ in range(3):
        ind = ind[:-2]
        W(ind + "}")
    W("      return %%arg1 : memref<1x1x1x%dxf16>" % nout)
    W("    }")
    W("  }")
    W("}")
    text = "\n".join(L) + "\n"
    return text.replace("%%", "%")


def build_kernel(key, cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad):
    kdir = os.path.join(CACHE, key)
    blob = os.path.join(kdir, "conv_npu.blob")
    if os.path.exists(blob):
        return blob
    os.makedirs(kdir, exist_ok=True)
    mlir = os.path.join(kdir, "conv.mlir")
    open(mlir, "w").write(mlir_kernel(cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad))
    carrier_onnx = os.path.join(kdir, "carrier.onnx")
    cx = helper.make_tensor_value_info("x", TensorProto.FLOAT16, [1, npad])
    cy = helper.make_tensor_value_info("y", TensorProto.FLOAT16, [1, npad])
    cg = helper.make_graph([helper.make_node(CARRIER_OP, ["x"], ["y"])], "carrier", [cx], [cy])
    cm = helper.make_model(cg, opset_imports=[helper.make_opsetid("", 17)])
    cm.ir_version = 9
    onnx.save(cm, carrier_onnx)
    carrier = os.path.join(kdir, "carrier.blob")
    r = subprocess.run([os.path.join(OV, "compile_tool"), "-m", carrier_onnx, "-d", "NPU", "-o", carrier,
                        "-ip", "FP16", "-op", "FP16"], env=ENV, cwd=OV, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("carrier compile failed for %s" % key)
    ll = os.path.join(kdir, "conv.ll")
    r = subprocess.run(["sh", os.path.join(GEN, "gen_kernel.sh"), mlir, ll], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("gen failed for %s: %s" % (key, (r.stderr or r.stdout)[-200:]))
    r = subprocess.run(["sh", os.path.join(GEN, "build.sh"), ll, carrier, blob], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(blob):
        raise RuntimeError("build failed for %s: %s" % (key, (r.stderr or r.stdout)[-200:]))
    return blob


_CORE = None
_REQUESTS = {}


def _request(blob):
    """One NPU request per blob, reused for every launch of that kernel (no per-launch process or device start)."""
    global _CORE
    if blob not in _REQUESTS:
        import openvino as ov
        if _CORE is None:
            _CORE = ov.Core()
        with open(blob, "rb") as f:
            data = f.read()
        _REQUESTS[blob] = _CORE.import_model(data, "NPU").create_infer_request()
    return _REQUESTS[blob]


def launch(blob, flat, nout):
    req = _request(blob)
    res = req.infer({0: flat.reshape(1, -1)})
    out = list(res.values())[0]
    return np.asarray(out, dtype=np.float32).reshape(-1)[:nout]


def run_conv(x, W, B, stride, pad):
    """x: (cin, hin, win) fp16; W: (cout, cin, k, k) fp16; B: (cout,) fp16. Returns (cout, ho, wo) float32."""
    cin, hin, win = x.shape
    cout, _, k, _ = W.shape
    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)))
    hp, wp = xp.shape[1], xp.shape[2]
    ho = (hp - k) // stride + 1
    wo = (wp - k) // stride + 1
    ho_t, hp_t, cblk, nx, nw, nb, nout, npad = plan(cin, cout, k, wp, stride, ho, wo)
    out = np.zeros((cout, ho, wo), dtype=np.float32)
    for ob in range(0, cout, cblk):
        blob = build_kernel("c%d_k%d_s%d_hp%d_wp%d_ho%d_wo%d_b%d" % (cin, k, stride, hp_t, wp, ho_t, wo, cblk),
                            cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad)
        for r0 in range(0, ho, ho_t):
            rows = xp[:, r0 * stride:r0 * stride + hp_t, :]
            flat = np.zeros(npad, dtype=np.float16)
            flat[:nx] = rows.reshape(-1)
            flat[nx:nx + nw] = W[ob:ob + cblk].reshape(-1)
            flat[nx + nw:nx + nw + nb] = B[ob:ob + cblk]
            got = launch(blob, flat, nout).reshape(cblk, ho_t, wo)
            out[ob:ob + cblk, r0:r0 + ho_t, :] = got
    return out
