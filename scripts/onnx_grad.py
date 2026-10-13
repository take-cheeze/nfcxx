#!/usr/bin/env python3
"""Reverse-mode gradients of an ONNX model by onnxsim's graph_grad (the Python package), for lib/uop/nfcuop_onnxgrad.cpp.

This is the fallback of the C++ library libnfconnxsim.so (scripts/onnxsim/nfc_onnxsim.cpp, which does the same with onnxsim's
C++ sources and is the primary path); keep the two in step. It needs `pip install onnx numpy onnxsim==0.8.1`.

usage: onnx_grad.py --model FORWARD.onnx --out GRAD.onnx --loss NAME --wrt NAME [--wrt NAME ...] [--prefix P] [--simplify]
       onnx_grad.py --check          exit 0 if the packages are importable (prints their versions)

FORWARD.onnx computes the scalar float tensor NAME (lib/uop exports the sub-graph of the loss with hir::Graph::to_onnx). GRAD.onnx
holds the same nodes plus the gradient nodes, with one graph output `<prefix>grad_<k>` per --wrt, in order. Every new tensor name
starts with the prefix. Only the operators onnxsim's C++ port differentiates are accepted (graph_grad.SUPPORTED_OPS), so that both
paths agree; the Python-only rules of the package (Slice, Where, Concat, ...) are not used. Exit status: 0 ok, 2 bad input or
failure, 3 an operator without a gradient rule (the message is the library's), 4 the packages are missing.
--simplify runs onnxsim.simplify over the result; it may rename or merge the forward values, so lib/uop does not use it.
"""
import argparse
import sys


def fail(code, msg):
    sys.stderr.write("onnx_grad: %s\n" % msg)
    sys.exit(code)


try:
    import numpy as np
    import onnx
    from onnx import TensorProto, helper, numpy_helper, shape_inference
    import onnxsim
    from onnxsim import graph_grad, qat_graph
except ImportError as e:  # pragma: no cover
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        sys.stderr.write("%s\n" % e)
    else:
        sys.stderr.write("onnx_grad: needs the python packages onnx, numpy and onnxsim==0.8.1: %s\n" % e)
    sys.exit(4)


def dims_of(vi):
    t = vi.type.tensor_type
    out = []
    for d in t.shape.dim:
        if not d.HasField("dim_value"):
            fail(2, "value %s has no static shape" % vi.name)
        out.append(d.dim_value)
    return out


def to_double(b):
    """The rules build float32 constants and Cast masks to FLOAT; a float64 model gets them in float64."""
    for i, t in enumerate(b.initializer):
        if t.data_type != TensorProto.FLOAT:
            continue
        a = numpy_helper.to_array(t).astype(np.float64)
        flat = a.reshape(-1)
        for k, v in enumerate(flat):  # the mean rules build 1/N in float32: recover N
            if 0 < v < 1:
                n = np.floor(1.0 / v + 0.5)
                if n >= 2 and np.float32(1.0 / n) == np.float32(v):
                    flat[k] = 1.0 / n
        b.initializer[i] = numpy_helper.from_array(flat.reshape(a.shape), t.name)
    for n in b.nodes:
        if n.op_type == "Cast":
            for a in n.attribute:
                if a.name == "to" and a.i == TensorProto.FLOAT:
                    a.i = TensorProto.DOUBLE


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--model")
    ap.add_argument("--out")
    ap.add_argument("--loss")
    ap.add_argument("--wrt", action="append", default=[])
    ap.add_argument("--prefix", default="nfcg_")
    ap.add_argument("--simplify", action="store_true")
    args = ap.parse_args()
    if args.check:
        print("onnx %s, onnxsim %s" % (onnx.__version__, onnxsim.__version__))
        return
    if not (args.model and args.out and args.loss and args.wrt):
        fail(2, "--model, --out, --loss and at least one --wrt are required")
    prefix = args.prefix

    model = onnx.load(args.model)
    model = shape_inference.infer_shapes(model)
    graph = model.graph
    shapes, dtypes = {}, {}
    for vi in list(graph.input) + list(graph.value_info) + list(graph.output):
        if vi.type.HasField("tensor_type"):
            shapes[vi.name] = dims_of(vi)
            dtypes[vi.name] = vi.type.tensor_type.elem_type
    for t in graph.initializer:
        shapes[t.name] = list(t.dims)
        dtypes[t.name] = t.data_type
    loss = args.loss
    if loss not in shapes:
        fail(2, "the loss %s is not a value of the model" % loss)
    if shapes[loss]:
        fail(2, "the loss %s must be a scalar, it has rank %d" % (loss, len(shapes[loss])))
    ldt = dtypes[loss]
    if ldt not in (TensorProto.FLOAT, TensorProto.DOUBLE):
        fail(2, "the loss %s must be float32 or float64" % loss)
    for w in args.wrt:
        if w not in shapes:
            fail(2, "cannot differentiate with respect to %s: not a value of the model" % w)
        if dtypes[w] not in (TensorProto.FLOAT, TensorProto.DOUBLE):
            fail(2, "cannot differentiate with respect to %s: not a float value" % w)

    nodes = list(graph.node)
    needed = {loss}
    need = [False] * len(nodes)
    for k in range(len(nodes) - 1, -1, -1):
        if any(o in needed for o in nodes[k].output):
            need[k] = True
            needed.update(i for i in nodes[k].input if i)
    dep = set(args.wrt)
    sl = []
    for k, n in enumerate(nodes):
        if need[k] and any(i and i in dep for i in n.input):
            dep.update(n.output)
            sl.append(n)
    for n in reversed(sl):  # same refusal, same wording as the C++ library, so both paths agree on what is supported
        if n.op_type not in graph_grad.SUPPORTED_OPS:
            fail(3, "no gradient rule for op type %r (node %r); graph_grad differentiates %s"
                 % (n.op_type, n.name or n.output[0], sorted(graph_grad.SUPPORTED_OPS)))

    targets = [w for w in args.wrt if w in needed]
    while True:
        b = qat_graph.GraphBuilder(prefix)
        seed = b.const(1.0, "seed")
        try:
            got = graph_grad.build_backward(b, sl, shapes, {loss: seed}, targets)
            break
        except graph_grad.UnsupportedOpError as e:
            fail(3, str(e))
        except ValueError as e:
            msg = str(e)
            key = "no gradient reaches '"
            p = msg.find(key)
            if p < 0:
                fail(2, msg)
            who = msg[p + len(key):msg.index("'", p + len(key))]
            if who not in targets:
                fail(2, msg)
            targets = [t for t in targets if t != who]
    if ldt == TensorProto.DOUBLE:
        to_double(b)

    tail_nodes, tail_init, results = [], [], []
    for k, w in enumerate(args.wrt):
        if w in got:
            src = got[w]
        else:
            z = qat_graph.GraphBuilder("%sz%d_" % (prefix, k))
            src = z.const(0.0, "zero")
            if shapes[w]:
                shape_c = z.name("shape")
                z.initializer.append(numpy_helper.from_array(np.asarray(shapes[w], dtype=np.int64), shape_c))
                src = z.op("Expand", [src, shape_c], "zeros")
            if dtypes[w] == TensorProto.DOUBLE:
                to_double(z)
            tail_nodes += z.nodes
            tail_init += z.initializer
        out = "%sgrad_%d" % (prefix, k)
        tail_nodes.append(helper.make_node("Identity", [src], [out]))
        results.append(out)

    # inline the model-local functions of the templated rules in a model of their own (opset 17, the forward values they
    # read declared as inputs); inlined bodies bring names like `tmp`, so everything new gets the prefix
    gnodes = list(b.nodes)
    if b.functions:
        made = {t.name for t in b.initializer} | {o for n in b.nodes for o in n.output}
        ins, seen = [], set()
        for n in b.nodes:
            for i in n.input:
                if i and i not in made and i not in seen:
                    seen.add(i)
                    ins.append(helper.make_tensor_value_info(i, dtypes[i], shapes[i]))
        gg = helper.make_graph(b.nodes, "rules", ins, [], initializer=b.initializer)
        opsets = [helper.make_opsetid("", 17)] + [helper.make_opsetid(d, 1) for d in sorted({f.domain for f in b.functions})]
        gm = helper.make_model(gg, opset_imports=opsets, functions=list(b.functions))
        gm.ir_version = model.ir_version
        gm = shape_inference.infer_shapes(gm)
        gm = onnx.inliner.inline_local_functions(gm)
        gnodes = list(gm.graph.node)
    fwd = {v.name for v in graph.input} | {t.name for t in graph.initializer} | {o for n in nodes for o in n.output}

    def fresh(nm):
        return nm if (not nm or nm in fwd or nm.startswith(prefix)) else prefix + nm

    inits = list(b.initializer)
    for n in gnodes + tail_nodes:
        for k, i in enumerate(n.input):
            n.input[k] = fresh(i)
    for n in gnodes:
        for k, o in enumerate(n.output):
            n.output[k] = fresh(o)
    for t in inits:
        t.name = fresh(t.name)

    out_nodes = [n for k, n in enumerate(nodes) if need[k]] + gnodes + tail_nodes
    og = helper.make_graph(out_nodes, "nfcuop_grad", list(graph.input), [],
                           initializer=list(graph.initializer) + inits + tail_init)
    out = helper.make_model(og, opset_imports=list(model.opset_import))
    out.ir_version = model.ir_version
    out.producer_name = "nfcuop-onnxsim"
    out = shape_inference.infer_shapes(out)
    types = {v.name: v for v in out.graph.value_info}
    for r in results:
        vi = out.graph.output.add()
        if r in types:
            vi.CopyFrom(types[r])
        vi.name = r
    if args.simplify:
        from onnxsim import simplify
        out, ok = simplify(out)
        if not ok:
            fail(2, "onnxsim.simplify could not validate the simplified model")
    onnx.save(out, args.out)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # any other failure: say what and where
        import traceback
        traceback.print_exc()
        fail(2, "%s: %s" % (type(e).__name__, e))
