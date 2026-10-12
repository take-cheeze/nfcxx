#!/usr/bin/env python3
"""Check the ONNX models that tests/uop/test_np.cpp wrote: onnx.checker must accept them, and onnxruntime must compute what
the UOp interpreter computed (the .json next to each .onnx has the inputs and the interpreter's outputs).
usage: onnx_check.py DIR"""
import glob, json, os, sys

try:
    import numpy as np, onnx, onnxruntime as ort
except ImportError as e:
    print("SKIP onnx_check: %s" % e)
    sys.exit(0)

NP = {"bool": np.bool_, "int32": np.int32, "int64": np.int64, "float32": np.float32, "float64": np.float64}

def arr(d):
    a = np.array([np.nan if x is None else x for x in d["data"]], dtype=NP[d["dtype"]])
    return a.reshape(d["shape"])

bad = 0
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.onnx")))
if not files:
    print("FAIL onnx_check: no models in %s" % sys.argv[1]); sys.exit(1)
for path in files:
    name = os.path.basename(path)[:-5]
    spec = json.load(open(path[:-5] + ".json"))
    model = onnx.load(path)
    try:
        onnx.checker.check_model(model, full_check=True)
    except Exception as e:
        print("FAIL %s: onnx.checker: %s" % (name, e)); bad += 1; continue
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    feeds = {k: arr(v) for k, v in spec["inputs"].items()}
    outs = [o.name for o in sess.get_outputs()]
    got = dict(zip(outs, sess.run(outs, feeds)))
    for oname, want in spec["outputs"].items():
        w = arr(want); g = got[oname]
        ok = (g.shape == w.shape and g.dtype == w.dtype and np.allclose(g.astype(np.float64), w.astype(np.float64), rtol=1e-5, atol=1e-6, equal_nan=True))
        if not ok:
            print("FAIL %s/%s: onnxruntime %s %s vs interpreter %s %s\n  ort: %s\n  uop: %s" % (name, oname, g.dtype, g.shape, w.dtype, w.shape, g.ravel()[:12], w.ravel()[:12]))
            bad += 1
    print("ok   %s: %d node(s), %d output(s) equal in onnxruntime %s" % (name, len(model.graph.node), len(spec["outputs"]), ort.__version__))
sys.exit(1 if bad else 0)
