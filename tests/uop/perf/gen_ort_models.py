# Writes the onnxruntime benchmark models (the same ops and sizes as gen_webgpu.py) as base64 in a JS file for
# webgpu_ort_bench.html. Usage: gen_ort_models.py OUT_JS
import base64, json, sys
from onnx import helper, TensorProto

VEC = [2**16, 2**20, 2**24]
MAT = [256, 512, 1024]

def model(op, shapes, out_shape, **kw):
  ins = [helper.make_tensor_value_info(f"x{i}", TensorProto.FLOAT, s) for i, s in enumerate(shapes)]
  out = helper.make_tensor_value_info("y", TensorProto.FLOAT, out_shape)
  node = helper.make_node(op, [f"x{i}" for i in range(len(shapes))], ["y"], **kw)
  m = helper.make_model(helper.make_graph([node], "g", ins, [out]), opset_imports=[helper.make_opsetid("", 13)])
  m.ir_version = 9  # the onnx runtimes in use read IR versions up to 13; onnx 1.23 writes 14
  return base64.b64encode(m.SerializeToString()).decode()

models = {}
for n in VEC:
  models[f"add:{n}"] = {"model": model("Add", [[n], [n]], [n]), "inputs": [n, n], "out": [n]}
  models[f"mul:{n}"] = {"model": model("Mul", [[n], [n]], [n]), "inputs": [n, n], "out": [n]}
  models[f"sqrt:{n}"] = {"model": model("Sqrt", [[n]], [n]), "inputs": [n], "out": [n]}
  models[f"sum:{n}"] = {"model": model("ReduceSum", [[n]], [], keepdims=0), "inputs": [n], "out": []}
for n in MAT:
  models[f"matmul:{n}"] = {"model": model("MatMul", [[n, n], [n, n]], [n, n]), "inputs": [n * n, n * n], "out": [n, n]}
open(sys.argv[1], "w").write("window.ORT_MODELS = " + json.dumps(models) + ";\n")
print("models", len(models), file=sys.stderr)
