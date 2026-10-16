#!/usr/bin/env python3
"""Cost the ONNX models that tests/uop/test_*.cpp wrote, with onnxsim's cost model (the same one fusion decisions and
the memory planner use): the per-kernel traffic of onnxsim.model_info, and the certified bounds of onnxsim.shape_cost.
The kernel model fuses elementwise chains and treats views as free, the bounds model charges every node's inputs and
outputs unfused, so the kernel total must not exceed the bounds total. The exception is a multi-pass op (softmax and the
norms), which the kernel model reads twice: those models are reported as multi-pass and not compared. A model the
bounds cannot cover completely is reported and skipped.
usage: onnx_cost.py DIR"""
import glob, os, sys

try:
    import onnx
    from onnxsim.model_info import _KERNEL_MULTIPASS_OPS, kernel_traffic_breakdown
    from onnxsim.shape_cost import bounds
except ImportError as e:
    print("SKIP onnx_cost: %s" % e)
    sys.exit(0)

bad = 0
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.onnx")))
for path in files:
    name = os.path.basename(path)
    model = onnx.load(path)
    kernel = sum(kernel_traffic_breakdown(model).values())
    cost = bounds(model)
    if not cost.complete or cost.mem_access_bytes.hi is None:
        print("skip %s: bounds incomplete (%s)" % (name, "; ".join(cost.notes) or "unbounded tensors"))
        continue
    unfused = cost.mem_access_bytes.hi
    if any(n.op_type in _KERNEL_MULTIPASS_OPS for n in model.graph.node):
        print("multi-pass %s: kernel %d, unfused %d bytes (not compared)" % (name, kernel, unfused))
    elif kernel > unfused:
        bad += 1
        print("FAIL %s: kernel traffic %d > unfused bound %d" % (name, kernel, unfused))
    else:
        print("ok %s: kernel %d <= unfused %d bytes" % (name, kernel, unfused))
print("%d models, %d failures" % (len(files), bad))
sys.exit(1 if bad else 0)
