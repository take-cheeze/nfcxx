"""Check run_conv against onnxruntime for the given (cin, cout, hin, k, pad, stride) configurations."""
import os
import sys
import time

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper, TensorProto

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import conv_npu  # noqa: E402

CONFIGS = [
    (128, 128, 56, 3, 1, 2),
    (256, 64, 56, 1, 0, 1),
    (256, 128, 56, 1, 0, 1),
    (256, 512, 56, 1, 0, 2),
    (512, 128, 28, 1, 0, 1),
    (512, 256, 28, 1, 0, 1),
]
if len(sys.argv) > 1 and sys.argv[1] == "all":
    CONFIGS = [(3, 64, 224, 7, 3, 2), (64, 64, 56, 1, 0, 1), (64, 64, 56, 3, 1, 1), (64, 256, 56, 1, 0, 1),
               (128, 128, 28, 3, 1, 1)] + CONFIGS

for cin, cout, hin, k, pad, stride in CONFIGS:
    rng = np.random.default_rng(cin * 1000 + cout)
    W = (rng.standard_normal((cout, cin, k, k)) * 0.1).astype(np.float16)
    B = (rng.standard_normal(cout) * 0.5).astype(np.float16)
    X = rng.standard_normal((cin, hin, hin)).astype(np.float16)
    t0 = time.time()
    got = conv_npu.run_conv(X, W, B, stride, pad)
    dt = time.time() - t0
    ho = got.shape[1]
    xn = helper.make_tensor_value_info("x", TensorProto.FLOAT16, [1, cin, hin, hin])
    yn = helper.make_tensor_value_info("y", TensorProto.FLOAT16, [1, cout, ho, ho])
    g = helper.make_graph([helper.make_node("Conv", ["x", "W", "B"], ["y"], kernel_shape=[k, k], pads=[pad] * 4,
                                            strides=[stride, stride])], "c", [xn], [yn],
                          initializer=[numpy_helper.from_array(W, "W"), numpy_helper.from_array(B, "B")])
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)])
    m.ir_version = 9
    p = os.path.expanduser("~/conv-npu-cache/ref_%d_%d_%d_%d_%d_%d.onnx" % (cin, cout, hin, k, pad, stride))
    onnx.save(m, p)
    ref = ort.InferenceSession(p, providers=["CPUExecutionProvider"]).run(None, {"x": X[None]})[0][0].astype(np.float32)
    d = np.abs(got - ref)
    print("cin %d cout %d hin %d k %d pad %d s %d: max abs diff %.4g | ref max %.4g | mean %.4g | %.1fs"
          % (cin, cout, hin, k, pad, stride, d.max(), np.abs(ref).max(), d.mean(), dt), flush=True)
