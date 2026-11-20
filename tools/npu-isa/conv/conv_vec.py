"""Vectorized conv on the NPU: hand-written LLVM IR with <8 x half> loads and <8 x float> accumulators.

Each kernel computes 8 output channels per iteration. Weights are laid out [i][kh][kw][o] so the 8 output channels
of one (i, kh, kw) are contiguous. Output is laid out (oh, ow, o) and transposed on the host.
Launch input (flat fp16): [padded x rows (cin, hp_t, wp)] [weights (cin, k, k, cblk)] [bias (cblk)] [zero pad].
Usage: conv_vec.py cin cout k hin pad stride tag
"""
import os
import subprocess
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper, TensorProto

GEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen")
OV = os.environ.get("OPENVINO_BIN", os.path.expanduser("~/openvino_git/bin/intel64/Release"))
ENV = dict(os.environ, LD_LIBRARY_PATH=os.path.expanduser("~/ze-loader/lib") + ":" + OV)
CACHE = os.environ.get("CONV_VEC_CACHE", os.path.expanduser("~/conv-vec-cache"))
LIMIT = 262144
CARRIER_OP = os.environ.get("CARRIER", "Abs")
SEED_LL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen", "relu_seed.ll")  # typed relu IR: provides the ABI preamble and wrapper
os.makedirs(CACHE, exist_ok=True)


def loop(name, n, pre, body):
    out = ["  br label %%%s_h" % name, "%s_h:" % name,
           "  %%%s_iv = phi i32 [ 0, %%%s ], [ %%%s_nx, %%%s_l ]" % (name, pre, name, name),
           "  %%%s_c = icmp slt i32 %%%s_iv, %d" % (name, name, n),
           "  br i1 %%%s_c, label %%%s_b, label %%%s_e" % (name, name, name),
           "%s_b:" % name]
    out += body("%%%s_iv" % name, name)
    out += ["  br label %%%s_l" % name, "%s_l:" % name,
            "  %%%s_nx = add i32 %%%s_iv, 1" % (name, name), "  br label %%%s_h" % name, "%s_e:" % name]
    return out


def loop_acc(name, n, pre, pre_acc, body):
    """Loop with a carried <8 x float> accumulator. body(iv, acc) -> (lines, new_acc_name). Returns (lines, result)."""
    out = [f"  br label %{name}_h", f"{name}_h:",
           f"  %{name}_iv = phi i32 [ 0, %{pre} ], [ %{name}_nx, %{name}_l ]",
           f"  %{name}_acc = phi <8 x float> [ {pre_acc}, %{pre} ], [ %{name}_accn, %{name}_l ]",
           f"  %{name}_c = icmp slt i32 %{name}_iv, {n}",
           f"  br i1 %{name}_c, label %{name}_b, label %{name}_e",
           f"{name}_b:"]
    lines, new = body(f"%{name}_iv", f"%{name}_acc")
    out += lines
    out += [f"  %{name}_accn = fadd <8 x float> {new}, zeroinitializer",
            f"  br label %{name}_l", f"{name}_l:",
            f"  %{name}_nx = add i32 %{name}_iv, 1",
            f"  br label %{name}_h", f"{name}_e:",
            f"  %{name}_res = phi <8 x float> [ %{name}_acc, %{name}_h ]"]
    return out, f"%{name}_res"


def kernel_ll(cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad, wb, bb):
    head, rest = open(SEED_LL).read().split("  br label %34", 1)
    tail = rest[rest.index("45:"):].replace("45:", "exit:", 1)
    HW = hp_t * wp
    lines = ["  br label %P0", "P0:",
             "  %xb = bitcast i8* %1 to half*", "  %ob_ = bitcast i8* %12 to half*"]

    def kw_body(iv, acc):
        # iv is the kw index; i and kh indices and the outer pixel are SSA names in scope
        return [
            f"  %xa = mul i32 %i_iv, {HW}",
            f"  %xb1 = mul i32 %oh_iv, {stride}",
            "  %xb2 = add i32 %xb1, %kh_iv",
            f"  %xb3 = mul i32 %xb2, {wp}",
            "  %xb4 = add i32 %xa, %xb3",
            f"  %xb5 = mul i32 %ow_iv, {stride}",
            "  %xb6 = add i32 %xb4, %xb5",
            f"  %xi = add i32 %xb6, {iv}",
            "  %xp = getelementptr half, half* %xb, i32 %xi",
            "  %xh = load half, half* %xp, align 2",
            "  %xf = fpext half %xh to float",
            "  %xs0 = insertelement <8 x float> undef, float %xf, i32 0",
            "  %xs = shufflevector <8 x float> %xs0, <8 x float> undef, <8 x i32> zeroinitializer",
            f"  %wa = mul i32 %i_iv, {k}",
            "  %wb1 = add i32 %wa, %kh_iv",
            f"  %wb2 = mul i32 %wb1, {k}",
            f"  %wb3 = add i32 %wb2, {iv}",
            f"  %wb4 = mul i32 %wb3, {cblk}",
            "  %wb5 = mul i32 %ob_iv, 8",
            "  %wb6 = add i32 %wb4, %wb5",
            f"  %widx = add i32 %wb6, {wb}",
            "  %wp = getelementptr half, half* %xb, i32 %widx",
            "  %wvp = bitcast half* %wp to <8 x half>*",
            "  %wh = load <8 x half>, <8 x half>* %wvp, align 2",
            "  %wf = fpext <8 x half> %wh to <8 x float>",
            f"  %pm = fmul <8 x float> %xs, %wf",
            f"  %an = fadd <8 x float> {acc}, %pm",
        ], "%an"

    def kh_body(iv, acc):
        lines, res = loop_acc("kw", k, "kh_b", acc, kw_body)
        return lines, res

    def i_body(iv, acc):
        lines, res = loop_acc("kh", k, "i_b", acc, kh_body)
        return lines, res

    def ob_body(iv, _):
        lines, res = loop_acc("i", cin, "ob_b", "zeroinitializer", i_body)
        out = list(lines)
        out += [
            "  %bo = mul i32 %ob_iv, 8",
            f"  %bidx = add i32 %bo, {bb}",
            "  %bp = getelementptr half, half* %xb, i32 %bidx",
            "  %bvp = bitcast half* %bp to <8 x half>*",
            "  %bh = load <8 x half>, <8 x half>* %bvp, align 2",
            "  %bf = fpext <8 x half> %bh to <8 x float>",
            f"  %yv = fadd <8 x float> {res}, %bf",
            "  %yh = fptrunc <8 x float> %yv to <8 x half>",
            f"  %oa = mul i32 %oh_iv, {wo}",
            "  %ob1 = add i32 %oa, %ow_iv",
            f"  %ob2 = mul i32 %ob1, {cblk}",
            "  %ob3 = add i32 %ob2, %bo",
            "  %op = getelementptr half, half* %ob_, i32 %ob3",
            "  %ovp = bitcast half* %op to <8 x half>*",
            "  store <8 x half> %yh, <8 x half>* %ovp, align 2",
        ]
        return out

    def ow_body(iv, _):
        return loop("ob", cblk // 8, "ow_b", ob_body)

    def oh_body(iv, _):
        return loop("ow", wo, "oh_b", ow_body)

    lines += loop("oh", ho_t, "P0", oh_body)
    lines += ["  br label %exit"]
    return head + "\n".join(lines) + "\n\n" + tail


def build(key, ll_text, npad):
    d = os.path.join(CACHE, key)
    blob = os.path.join(d, "conv_vec.blob")
    if os.path.exists(blob):
        return blob
    os.makedirs(d, exist_ok=True)
    ll = os.path.join(d, "conv_vec.ll")
    open(ll, "w").write(ll_text)
    carrier_onnx = os.path.join(d, "carrier.onnx")
    cx = helper.make_tensor_value_info("x", TensorProto.FLOAT16, [1, npad])
    cy = helper.make_tensor_value_info("y", TensorProto.FLOAT16, [1, npad])
    cg = helper.make_graph([helper.make_node(CARRIER_OP, ["x"], ["y"])], "carrier", [cx], [cy])
    cm = helper.make_model(cg, opset_imports=[helper.make_opsetid("", 17)])
    cm.ir_version = 9
    onnx.save(cm, carrier_onnx)
    carrier = os.path.join(d, "carrier.blob")
    r = subprocess.run([os.path.join(OV, "compile_tool"), "-m", carrier_onnx, "-d", "NPU", "-o", carrier,
                        "-ip", "FP16", "-op", "FP16"], env=ENV, cwd=OV, capture_output=True, text=True)
    assert r.returncode == 0, "carrier compile failed"
    r = subprocess.run(["sh", os.path.join(GEN, "build.sh"), ll, carrier, blob], capture_output=True, text=True)
    assert r.returncode == 0 and os.path.exists(blob), "build failed: " + (r.stdout + r.stderr)[-400:]
    return blob


if __name__ == "__main__":
    cin, cout, k, hin, pad, stride = (int(v) for v in sys.argv[1:7])
    tag = sys.argv[7]
    hp = hin + 2 * pad
    ho = (hp - k) // stride + 1
    wo = ho
    wp = hp
    # launch sizes: cblk multiple of 8 dividing cout, ho_t dividing ho, launch <= LIMIT
    best = None
    for ho_t in sorted([d for d in range(1, ho + 1) if ho % d == 0], reverse=True):
        hp_t = (ho_t - 1) * stride + k
        for cblk in sorted([c for c in range(8, cout + 1, 8) if cout % c == 0], reverse=True):
            nx = cin * hp_t * wp
            nw = cblk * cin * k * k
            nout = ho_t * wo * cblk
            npad = max(nx + nw + cblk, nout)
            if npad <= LIMIT:
                best = (ho_t, hp_t, cblk, nx, nw, npad, nout)
                break
        if best:
            break
    assert best, "no tile"
    ho_t, hp_t, cblk, nx, nw, npad, nout = best
    wb, bb = nx, nx + nw
    print("tile: ho_t", ho_t, "cblk", cblk, "npad", npad, "launches", (cout // cblk) * (ho // ho_t))
    key = "c%d_k%d_s%d_hp%d_wp%d_ho%d_b%d" % (cin, k, stride, hp_t, wp, ho_t, cblk)
    blob = build(key, kernel_ll(cin, k, stride, hp_t, wp, ho_t, wo, cblk, npad, wb, bb), npad)
    rng = np.random.default_rng(42)
    W = (rng.standard_normal((cout, cin, k, k)) * 0.1).astype(np.float16)
    B = (rng.standard_normal(cout) * 0.5).astype(np.float16)
    X = rng.standard_normal((1, cin, hin, hin)).astype(np.float16)
    xn = helper.make_tensor_value_info("x", TensorProto.FLOAT16, [1, cin, hin, hin])
    yn = helper.make_tensor_value_info("y", TensorProto.FLOAT16, [1, cout, ho, wo])
    g = helper.make_graph([helper.make_node("Conv", ["x", "W", "B"], ["y"], kernel_shape=[k, k], pads=[pad] * 4,
                                            strides=[stride, stride])], "c", [xn], [yn],
                          initializer=[numpy_helper.from_array(W, "W"), numpy_helper.from_array(B, "B")])
    mdl = helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)])
    mdl.ir_version = 9
    refp = os.path.join(CACHE, "ref_%s.onnx" % tag)
    onnx.save(mdl, refp)
    ref = ort.InferenceSession(refp, providers=["CPUExecutionProvider"]).run(None, {"x": X})[0][0].astype(np.float32)
    xp = np.pad(X[0], ((0, 0), (pad, pad), (pad, pad)))
    got = np.zeros((cout, ho, wo), dtype=np.float32)
    inp_dir = os.path.join(CACHE, key)
    for b0 in range(0, cout, cblk):
        for r0 in range(0, ho, ho_t):
            rows = xp[:, r0 * stride:r0 * stride + hp_t, :].reshape(-1)
            Wb = W[b0:b0 + cblk]                                   # (cblk, cin, k, k)
            Wt = np.ascontiguousarray(Wb.transpose(1, 2, 3, 0)).reshape(-1)   # (cin, k, k, cblk)
            flat = np.zeros(npad, dtype=np.float16)
            flat[:nx] = rows
            flat[wb:wb + nw] = Wt
            flat[bb:bb + cblk] = B[b0:b0 + cblk]
            inp = os.path.join(inp_dir, "in_%d_%d.bin" % (b0, r0))
            flat.tofile(inp)
            od = os.path.join(inp_dir, "out")
            os.makedirs(od, exist_ok=True)
            for f in os.listdir(od):
                os.remove(os.path.join(od, f))
            r = subprocess.run([os.path.join(OV, "infer_tool"), "-m", blob, "-d", "NPU", "-i", inp, "-o", od],
                               env=ENV, cwd=OV, capture_output=True, text=True)
            assert r.returncode == 0, "run failed: " + (r.stdout + r.stderr).strip().splitlines()[-1][:160]
            out = np.fromfile(os.path.join(od, os.listdir(od)[0]), dtype=np.float16).astype(np.float32)[:nout]
            tile = out.reshape(ho_t, wo, cblk).transpose(2, 0, 1)   # (cblk, ho_t, wo)
            got[b0:b0 + cblk, r0:r0 + ho_t, :] = tile
    d = np.abs(got - ref)
    print("RESULT %s: max abs diff %.4g | ref max %.4g | mean %.4g | finite %s"
          % (tag, d.max(), np.abs(ref).max(), d.mean(), bool(np.isfinite(got).all())))
