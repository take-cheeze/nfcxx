"""Correctness of dpu_single_op.run for the DPU-only ops from NOTES.md, against numpy references on the same inputs.
Run on the NPU machine: python test_dpu_single_op.py"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dpu_single_op as dso  # noqa: E402

rng = np.random.default_rng(0)


def rel(got, ref):
    return float(np.abs(got - ref).max() / max(np.abs(ref).max(), 1e-6))


def check(name, got, ref):
    r = rel(got, ref)
    print("%-14s rel err %.2e %s" % (name, r, "ok" if r < 2e-3 else "FAIL"), flush=True)
    return r < 2e-3


ok = True
a = rng.standard_normal((1, 64, 28, 28)).astype(np.float32)
b = rng.standard_normal((1, 64, 28, 28)).astype(np.float32)
ok &= check("sub", dso.run("Sub", [a, b], [1, 64, 28, 28]), a - b)

pool = a.reshape(1, 64, 14, 2, 14, 2).mean(axis=(3, 5))
ok &= check("avgpool", dso.run("AveragePool", [a], [1, 64, 14, 14], attrs={"kernel_shape": [2, 2], "strides": [2, 2]}), pool)

ok &= check("reducemean", dso.run("ReduceMean", [a], [1, 64, 1, 1], attrs={"axes": [2, 3], "keepdims": 1}),
            a.mean(axis=(2, 3), keepdims=True))

scales = np.array([1, 1, 2, 2], np.float32)
up = np.repeat(np.repeat(a, 2, axis=2), 2, axis=3)
ok &= check("resize", dso.run("Resize", [a], [1, 64, 56, 56], attrs={"mode": "nearest"}, consts={1: None, 2: scales}), up)

W = rng.standard_normal((32, 64, 2, 2)).astype(np.float32)
x = rng.standard_normal((1, 32, 28, 28)).astype(np.float32)
# ConvTranspose with kernel 2 and stride 2: y[n, o, 2h+i, 2w+j] = sum_c x[n, c, h, w] * W[c, o, i, j]
ref = np.zeros((1, 64, 56, 56), np.float32)
for i in range(2):
    for j in range(2):
        ref[:, :, i::2, j::2] = np.einsum("nchw,co->nohw", x, W[:, :, i, j])
ok &= check("convtranspose", dso.run("ConvTranspose", [x], [1, 64, 56, 56],
                                     attrs={"kernel_shape": [2, 2], "strides": [2, 2]}, consts={1: W}), ref)

print("all ok" if ok else "some FAILED", flush=True)
