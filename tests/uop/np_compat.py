#!/usr/bin/env python3
"""Compare nfcuop::np with real numpy on the expressions of tests/uop/np_compat.cpp (same names, same inputs).
Values and shapes must match (rtol 1e-5); a dtype difference is reported, and fails only if it is not one of the
documented ones (DTYPE_DIFFS: numpy's default int64/float64 where nfcuop uses int32/float32).
usage: np_compat.py RESULT.json"""
import json, sys

try:
    import numpy as np
except ImportError as e:
    print("SKIP np_compat: %s" % e)
    sys.exit(0)

f32, i32 = np.float32, np.int32
a = np.arange(1, 7, dtype=f32).reshape(2, 3)
b = np.array([10, 20, 30], f32)
ia = np.array([[7, -7, 3], [-3, 2, -5]], i32)
ib = np.array([2, -2, 3], i32)
m = np.arange(24, dtype=f32).reshape(2, 3, 4)
v = np.array([-2, -.5, 0, .5, 2], f32)
bo = np.array([[1, 0, 1], [0, 0, 1]], bool)

def softmax(x): e = np.exp(x - x.max(-1, keepdims=True)); return e / e.sum(-1, keepdims=True)
def logsoftmax(x): z = x - x.max(-1, keepdims=True); return z - np.log(np.exp(z).sum(-1, keepdims=True))

CASES = {
    "add": lambda: a + b, "sub": lambda: a - b, "mul": lambda: a * b, "div": lambda: a / b,
    "add_s": lambda: a + 1, "radd_s": lambda: 2 * a, "sub_f": lambda: a - 0.5, "rdiv_s": lambda: 3 / a, "neg": lambda: -a,
    "square": lambda: a * a, "abs": lambda: np.abs(a - 3),
    "iadd": lambda: ia + ib, "imul": lambda: ia * ib, "isub": lambda: ia - ib, "idiv_true": lambda: ia / ib,
    "ifloordiv": lambda: ia // ib, "imod": lambda: ia % ib, "ifloordiv_s": lambda: ia // 2, "imod_s": lambda: ia % 3,
    "gt": lambda: a > 2, "le": lambda: a <= b, "eq": lambda: a == a, "ne_s": lambda: a != 2,
    "and": lambda: (a > 2) & (a < 5), "or": lambda: (a < 2) | (a > 5), "xor": lambda: (a > 2) ^ (a > 4),
    "not": lambda: ~(a > 2), "band": lambda: bo & (a > 2),
    "iand": lambda: ia & ib, "ior": lambda: ia | ib, "ixor": lambda: ia ^ ib,
    "where": lambda: np.where(a > 3, a, 0), "maximum_s": lambda: np.maximum(a, 3),
    "minimum": lambda: np.minimum(a, b), "clip": lambda: np.clip(a, 2, 5),
    "sum_all": lambda: a.sum(), "sum0": lambda: a.sum(0), "sum1k": lambda: a.sum(1, keepdims=True),
    "mean_all": lambda: a.mean(), "mean0": lambda: a.mean(0), "max_all": lambda: a.max(), "min1": lambda: a.min(1),
    "isum": lambda: ia.sum(), "imax0": lambda: ia.max(0), "imin": lambda: ia.min(), "bsum": lambda: bo.sum(),
    "var": lambda: a.var(), "std0": lambda: a.std(0), "sum02": lambda: m.sum((0, 2)), "maxlast": lambda: m.max(axis=-1),
    "imean": lambda: ia.mean(),
    "T": lambda: a.T, "reshape": lambda: a.reshape(3, 2), "reshape_1": lambda: a.reshape(-1),
    "transpose3": lambda: m.transpose(2, 0, 1), "swapaxes": lambda: m.swapaxes(0, 2), "flatten": lambda: a.flatten(),
    "expand_dims": lambda: np.expand_dims(a, 1), "squeeze": lambda: np.squeeze(np.expand_dims(a, 1)),
    "broadcast_to": lambda: np.broadcast_to(b, (2, 3)),
    "astype_i": lambda: a.astype(i32), "astype_f": lambda: ia.astype(f32), "neg_cast": lambda: (-a).astype(i32),
    "slice1": lambda: m[:, 1:3, ::2], "slice_rev": lambda: m[..., ::-1], "slice_int": lambda: m[1], "slice_last": lambda: m[:, -1],
    "slice_rev0": lambda: a[::-1], "slice_col": lambda: a[:, 1:], "slice_mixed": lambda: m[0, 1:, 1:3], "slice_neg": lambda: m[:, :, -3:-1],
    "concat0": lambda: np.concatenate([a, a], 0), "concat1": lambda: np.concatenate([a, a * 2], 1),
    "stack0": lambda: np.stack([a, a + 1]), "stack2": lambda: np.stack([a, a + 1], axis=2),
    "exp": lambda: np.exp(v), "log": lambda: np.log(np.abs(v) + 1), "sqrt": lambda: np.sqrt(np.abs(v)), "sin": lambda: np.sin(v),
    "cos": lambda: np.cos(v), "tanh": lambda: np.tanh(v), "sigmoid": lambda: 1 / (1 + np.exp(-v)), "relu": lambda: np.maximum(v, 0),
    "recip": lambda: 1 / v, "softmax": lambda: softmax(a), "logsoftmax": lambda: logsoftmax(a),
    "matmul_aat": lambda: a @ a.T, "matmul_ab": lambda: a @ b, "matmul_ba": lambda: b @ a.T,
    "matmul_batch": lambda: m @ np.ones((4, 2), f32), "matmul_gram": lambda: m @ m.transpose(0, 2, 1),
    "matmul_vv": lambda: b @ b, "matmul_int": lambda: ia @ ia.T,
    "arange": lambda: np.arange(5), "arange_step": lambda: np.arange(1.0, 2.0, 0.25), "linspace": lambda: np.linspace(0, 1, 5),
    "eye": lambda: np.eye(3), "zeros": lambda: np.zeros((2, 2)), "ones_i": lambda: np.ones((2,), i32), "full": lambda: np.full((2,), 7),
}

# nfcuop's dtype differs from numpy's on purpose: ints are int32 and floats float32 unless asked otherwise, so numpy's
# int64 / float64 defaults (sums, means, true division of ints, arange, linspace, eye, zeros, full) differ
DTYPE_DIFFS = {"idiv_true", "isum", "imean", "bsum", "mean_all_i", "arange", "arange_step", "linspace", "eye", "zeros", "full"}

got = json.load(open(sys.argv[1]))
if set(got) != set(CASES):
    print("FAIL np_compat: case lists differ: %s" % sorted(set(got) ^ set(CASES))); sys.exit(1)
ND = {"bool": "bool", "int32": "int32", "int64": "int64", "float32": "float32", "float64": "float64"}
errs = np.errstate(all="ignore"); errs.__enter__()
same = diff_ok = 0; bad = []; dtype_diffs = []
for name, fn in CASES.items():
    want = np.asarray(fn()); g = got[name]
    gv = np.array([np.nan if x is None else x for x in g["data"]], dtype=np.float64).reshape(g["shape"])
    wv = want.astype(np.float64)
    if gv.shape != wv.shape:
        bad.append("%s: shape %s vs numpy %s" % (name, gv.shape, wv.shape)); continue
    if not np.allclose(gv, wv, rtol=1e-5, atol=1e-6, equal_nan=True):
        bad.append("%s: values %s vs numpy %s" % (name, gv.ravel()[:8], wv.ravel()[:8])); continue
    if g["dtype"] != want.dtype.name:
        dtype_diffs.append((name, g["dtype"], want.dtype.name))
        if name not in DTYPE_DIFFS: bad.append("%s: dtype %s, numpy gives %s (not a documented difference)" % (name, g["dtype"], want.dtype.name))
    else:
        same += 1
total = len(CASES)
print("numpy compatibility: %d expressions; %d match numpy in shape, values and dtype; %d match in shape and values with a different dtype; %d differ"
      % (total, same, len(dtype_diffs), len([x for x in bad if "dtype" not in x])))
for n, o, w in dtype_diffs: print("  dtype: %-12s nfcuop %-8s numpy %s" % (n, o, w))
for x in bad: print("FAIL " + x)
sys.exit(1 if bad else 0)
