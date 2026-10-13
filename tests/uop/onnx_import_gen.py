#!/usr/bin/env python3
"""Writes ONNX models made with the onnx package (not by nfcuop) together with the inputs and what onnxruntime computes, for the
importer test tests/uop/test_onnx.cpp (hir::Graph::from_onnx): DIR/<name>.onnx and DIR/<name>.json (same layout as the models of
test_np.cpp: {"inputs": {name: array}, "outputs": {name: array}}).
usage: onnx_import_gen.py DIR"""
import json, os, sys

try:
    import numpy as np, onnx, onnxruntime as ort
    from onnx import TensorProto as TP, helper as h, numpy_helper as nh
except ImportError as e:
    print("SKIP onnx_import_gen: %s" % e)
    sys.exit(0)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rng = np.random.RandomState(7)

def arr_json(a):
    names = {np.dtype("bool"): "bool", np.dtype("int32"): "int32", np.dtype("int64"): "int64", np.dtype("float32"): "float32", np.dtype("float64"): "float64"}
    return {"dtype": names[a.dtype], "shape": list(a.shape), "data": [None if (isinstance(x, float) and x != x) else (bool(x) if a.dtype == np.bool_ else x.item()) for x in a.reshape(-1)]}

def vi(name, dt, shape):
    return h.make_tensor_value_info(name, dt, shape)

def save(name, graph, opset, feeds, ir=8):
    m = h.make_model(graph, opset_imports=[h.make_opsetid("", opset)])
    m.ir_version = ir
    onnx.checker.check_model(m, full_check=True)
    path = os.path.join(out, name + ".onnx")
    onnx.save(m, path)
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    names = [o.name for o in sess.get_outputs()]
    got = sess.run(names, feeds)
    spec = {"inputs": {k: arr_json(v) for k, v in feeds.items()}, "outputs": {n: arr_json(g) for n, g in zip(names, got)}}
    json.dump(spec, open(os.path.join(out, name + ".json"), "w"))

f32 = np.float32
x = rng.uniform(-1, 1, (3, 4)).astype(f32)
w = rng.uniform(-1, 1, (4, 2)).astype(f32)

# 1. typed (not raw) initializer data, Constant nodes of every flavour, an initializer that is also a graph input (IR 3 style)
w_typed = h.make_tensor("w", TP.FLOAT, [4, 2], [float(v) for v in w.reshape(-1)])
ints_typed = h.make_tensor("shape", TP.INT64, [2], [3, 2])
g = h.make_graph(
    [
        h.make_node("MatMul", ["x", "w"], ["y"]),
        h.make_node("Constant", [], ["half"], value_float=0.5),
        h.make_node("Constant", [], ["bias"], value=nh.from_array(np.array([0.25, -0.5], dtype=f32), "b")),
        h.make_node("Constant", [], ["sh"], value_ints=[2, 3]),
        h.make_node("Constant", [], ["scal"], value=nh.from_array(np.array(2.0, dtype=f32), "s")),
        h.make_node("Add", ["y", "bias"], ["yb"]),
        h.make_node("Mul", ["yb", "half"], ["ym"]),
        h.make_node("Reshape", ["ym", "sh"], ["r"]),
        h.make_node("Mul", ["r", "scal"], ["z"]),
        h.make_node("Reshape", ["z", "shape"], ["z2"]),
    ],
    "typed", [vi("x", TP.FLOAT, [3, 4]), vi("w", TP.FLOAT, [4, 2])], [vi("z", TP.FLOAT, [2, 3]), vi("z2", TP.FLOAT, [3, 2])],
    initializer=[w_typed, ints_typed])
save("imp_typed", g, 17, {"x": x}, ir=4)

# 2. attributes: Cast to, Transpose perm, Softmax axis, Concat axis, Clip min/max inputs, ReduceMean with axes as an attribute (opset 17),
#    ReduceSum with axes as an input, Squeeze/Unsqueeze axes as inputs, Gemm-free; a Where on int64 and bool
g = h.make_graph(
    [
        h.make_node("Transpose", ["x"], ["xt"], perm=[1, 0]),
        h.make_node("Softmax", ["xt"], ["sm"], axis=0),
        h.make_node("Concat", ["sm", "xt"], ["cc"], axis=1),
        h.make_node("Clip", ["cc", "lo", "hi"], ["cl"]),
        h.make_node("ReduceMean", ["cl"], ["rm"], axes=[1], keepdims=1),
        h.make_node("ReduceSum", ["cl", "ax0"], ["rs"], keepdims=0),
        h.make_node("Unsqueeze", ["rs", "ax0"], ["us"]),
        h.make_node("Squeeze", ["us", "ax0"], ["sq"]),
        h.make_node("Cast", ["x"], ["xi"], to=TP.INT64),
        h.make_node("Greater", ["x", "zero"], ["gt"]),
        h.make_node("Where", ["gt", "x", "negx"], ["wh"]),
        h.make_node("Neg", ["x"], ["negx"]),
    ],
    "attrs", [vi("x", TP.FLOAT, [3, 4])], [vi("rm", TP.FLOAT, [4, 1]), vi("sq", TP.FLOAT, [6]), vi("xi", TP.INT64, [3, 4]), vi("wh", TP.FLOAT, [3, 4]), vi("gt", TP.BOOL, [3, 4])],
    initializer=[nh.from_array(np.array(-0.2, dtype=f32), "lo"), nh.from_array(np.array(0.3, dtype=f32), "hi"), nh.from_array(np.array([0], dtype=np.int64), "ax0"),
                 nh.from_array(np.array(0.0, dtype=f32), "zero")])
# nodes must be topologically sorted: move Neg before Where
nodes = list(g.node)
neg = nodes.pop(11)
nodes.insert(10, neg)
del g.node[:]
g.node.extend(nodes)
save("imp_attrs", g, 17, {"x": x})

# 3. float64 and int32 with broadcasting, Max/Min/Mod/Equal
d = rng.uniform(-3, 3, (2, 3)).astype(np.float64)
e = np.array([[1, 2, 3], [4, 5, 6]], dtype=np.int32)
g = h.make_graph(
    [
        h.make_node("Sin", ["d"], ["s"]),
        h.make_node("Max", ["s", "dd"], ["mx"]),
        h.make_node("Min", ["d", "dd"], ["mn"]),
        h.make_node("Mod", ["e", "three"], ["md"]),
        h.make_node("Equal", ["md", "one"], ["eq"]),
        h.make_node("Div", ["mx", "mn"], ["dv"]),
    ],
    "f64", [vi("d", TP.DOUBLE, [2, 3]), vi("e", TP.INT32, [2, 3])], [vi("dv", TP.DOUBLE, [2, 3]), vi("md", TP.INT32, [2, 3]), vi("eq", TP.BOOL, [2, 3])],
    initializer=[nh.from_array(np.array([0.5, -0.25, 1.0], dtype=np.float64), "dd"), nh.from_array(np.array(3, dtype=np.int32), "three"), nh.from_array(np.array(1, dtype=np.int32), "one")])
save("imp_f64", g, 18, {"d": d, "e": e})

# 4. a model through onnx's own shape inference and the onnx optimizer-free path: slices with steps, Pad, Expand
g = h.make_graph(
    [
        h.make_node("Slice", ["x", "st", "en", "axs", "stp"], ["sl"]),
        h.make_node("Pad", ["sl", "pads"], ["pd"]),
        h.make_node("Expand", ["pd", "shp"], ["ex"]),
        h.make_node("LogSoftmax", ["ex"], ["ls"], axis=-1),
        h.make_node("Abs", ["ls"], ["ab"]),
    ],
    "slices", [vi("x", TP.FLOAT, [3, 4])], [vi("ab", TP.FLOAT, [4, 2, 3])],
    initializer=[nh.from_array(np.array(a, dtype=np.int64), n) for n, a in
                 [("st", [0, 3]), ("en", [3, -5]), ("axs", [0, 1]), ("stp", [2, -2]), ("pads", [0, 1, 0, 0]), ("shp", [4, 2, 3])]])
save("imp_slices", g, 18, {"x": x})

# 5. the forward operators of hir (Conv with groups, MaxPool, AveragePool, the three normalizations, Gemm, Erf, Gather) as the onnx
#    package writes them (its own attribute encoding, opset 18), computed by onnxruntime
xc = rng.uniform(-1, 1, (2, 3, 6, 5)).astype(f32)
w4 = rng.uniform(-1, 1, (4, 3, 2, 2)).astype(f32)
w3 = rng.uniform(-1, 1, (3, 1, 2, 2)).astype(f32)
g = h.make_graph(
    [
        h.make_node("Conv", ["x", "w4", "b4"], ["c1"], strides=[1, 2], pads=[0, 1, 1, 0]),
        h.make_node("Conv", ["x", "w3"], ["c2"], group=3, strides=[1, 2], pads=[0, 1, 1, 0]),
    ],
    "conv", [vi("x", TP.FLOAT, [2, 3, 6, 5])], [vi("c1", TP.FLOAT, [2, 4, 6, 3]), vi("c2", TP.FLOAT, [2, 3, 6, 3])],
    initializer=[nh.from_array(w4, "w4"), nh.from_array(w3, "w3"), nh.from_array(np.array([0.5, -0.5, 0.25, 0.0], dtype=f32), "b4")])
save("imp_fwd_conv", g, 18, {"x": xc})

xp = rng.uniform(-2, 2, (2, 3, 4, 5)).astype(f32)
g = h.make_graph(
    [
        h.make_node("MaxPool", ["x"], ["mp"], kernel_shape=[2, 2], strides=[2, 2]),
        h.make_node("AveragePool", ["x"], ["ap"], kernel_shape=[3, 3], pads=[1, 1, 1, 1]),
        h.make_node("BatchNormalization", ["x", "s", "b", "mu", "va"], ["bn"], epsilon=0.001),
        h.make_node("InstanceNormalization", ["x", "s", "b"], ["inn"]),
        h.make_node("LayerNormalization", ["x", "ls", "lb"], ["lnn"], axis=-2),
        h.make_node("Gemm", ["a", "w2", "c2"], ["gm"], alpha=1.5, beta=0.5, transB=0),
        h.make_node("Erf", ["gm"], ["ef"]),
        h.make_node("Gather", ["ef", "gidx"], ["gat"], axis=0),
    ],
    "pool_norm", [vi("x", TP.FLOAT, [2, 3, 4, 5]), vi("a", TP.FLOAT, [3, 4])],
    [vi("mp", TP.FLOAT, [2, 3, 2, 2]), vi("ap", TP.FLOAT, [2, 3, 4, 5]), vi("bn", TP.FLOAT, [2, 3, 4, 5]), vi("inn", TP.FLOAT, [2, 3, 4, 5]),
     vi("lnn", TP.FLOAT, [2, 3, 4, 5]), vi("gat", TP.FLOAT, [2, 2])],
    initializer=[nh.from_array(np.array([0.5, 1.0, 1.5], dtype=f32), "s"), nh.from_array(np.array([0.1, -0.1, 0.0], dtype=f32), "b"),
                 nh.from_array(np.array([0.0, 0.2, -0.4], dtype=f32), "mu"), nh.from_array(np.array([1.0, 0.5, 2.0], dtype=f32), "va"),
                 nh.from_array(rng.uniform(0.5, 1.5, (4, 5)).astype(f32), "ls"), nh.from_array(rng.uniform(-0.5, 0.5, (4, 5)).astype(f32), "lb"),
                 nh.from_array(rng.uniform(-1, 1, (4, 2)).astype(f32), "w2"), nh.from_array(np.array([0.25, -0.5], dtype=f32), "c2"),
                 nh.from_array(np.array([1, 0], dtype=np.int64), "gidx")])
save("imp_fwd_pool_norm", g, 18, {"x": xp, "a": rng.uniform(-1, 1, (3, 4)).astype(f32)})
