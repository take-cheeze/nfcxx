#!/usr/bin/env python3
# Real models for the back ends: an MLP and a small CNN, exported as ONNX at batch 1 and batch 32, run by onnxruntime (CPU),
# by tinygrad's ONNX frontend (tinygrad.nn.onnx) and by nfcxx's C backend (bench_models.cpp). Each back end's median run time
# is written as a JSON line; the outputs are compared with onnxruntime's. A back end whose output differs by more than
# 1e-4 relative is reported as wrong and its time is not used.
#
#   models.py export DIR                       write DIR/<model>_b<batch>.onnx, .in.bin (the input, float32) and the weights seed
#   models.py ort DIR [RUNS WARM]              onnxruntime CPU: DIR/<case>.ort.json and DIR/<case>.ort.bin
#   models.py tinygrad DIR [RUNS WARM]         tinygrad (the default device): DIR/<case>.tinygrad.json and .bin
#   models.py compare DIR                      the table lines of every case and back end, and the errors, to stdout as JSON
import json, os, shutil, statistics, sys, time

import numpy as np

MODELS = ["mlp", "cnn"]
BATCHES = [1, 32]
REL_TOL = 1e-4


def case_name(model, batch):
    return f"{model}_b{batch}"


def export(d):
    import onnx
    from onnx import TensorProto as TP, helper as h, numpy_helper as nh

    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(0)

    def init(name, a):
        return nh.from_array(np.asarray(a, dtype=np.float32), name)

    # One set of weights per model, shared by every batch size.
    w = {
        "mlp": {
            "W1": rng.standard_normal((784, 256)).astype(np.float32) * 0.05, "b1": np.zeros(256, np.float32),
            "W2": rng.standard_normal((256, 10)).astype(np.float32) * 0.05, "b2": np.zeros(10, np.float32),
        },
        "cnn": {
            "C1": rng.standard_normal((16, 1, 3, 3)).astype(np.float32) * 0.2, "c1": np.zeros(16, np.float32),
            "S1": np.ones(16, np.float32), "B1": np.zeros(16, np.float32),
            "M1": rng.standard_normal(16).astype(np.float32) * 0.1, "V1": np.ones(16, np.float32),
            "C2": rng.standard_normal((32, 16, 3, 3)).astype(np.float32) * 0.1, "c2": np.zeros(32, np.float32),
            "S2": np.ones(32, np.float32), "B2": np.zeros(32, np.float32),
            "M2": rng.standard_normal(32).astype(np.float32) * 0.1, "V2": np.ones(32, np.float32),
            "FW": rng.standard_normal((32 * 7 * 7, 10)).astype(np.float32) * 0.05, "fb": np.zeros(10, np.float32),
        },
    }

    def mlp(batch):
        W = w["mlp"]
        inits = [init(k, v) for k, v in W.items()]
        nodes = [
            h.make_node("Gemm", ["x", "W1", "b1"], ["h1"], name="fc1"),
            h.make_node("Relu", ["h1"], ["r1"], name="relu1"),
            h.make_node("Gemm", ["r1", "W2", "b2"], ["y"], name="fc2"),
        ]
        return nodes, inits, [h.make_tensor_value_info("x", TP.FLOAT, [batch, 784])], \
            [h.make_tensor_value_info("y", TP.FLOAT, [batch, 10])]

    def cnn(batch):
        W = w["cnn"]
        inits = [init(k, v) for k, v in W.items()]
        inits.append(nh.from_array(np.array([batch, 32 * 7 * 7], np.int64), "shape"))
        nodes = [
            h.make_node("Conv", ["x", "C1", "c1"], ["k1"], name="conv1", pads=[1, 1, 1, 1], kernel_shape=[3, 3]),
            h.make_node("BatchNormalization", ["k1", "S1", "B1", "M1", "V1"], ["n1"], name="bn1", epsilon=1e-5),
            h.make_node("Relu", ["n1"], ["r1"], name="relu1"),
            h.make_node("MaxPool", ["r1"], ["p1"], name="pool1", kernel_shape=[2, 2], strides=[2, 2]),
            h.make_node("Conv", ["p1", "C2", "c2"], ["k2"], name="conv2", pads=[1, 1, 1, 1], kernel_shape=[3, 3]),
            h.make_node("BatchNormalization", ["k2", "S2", "B2", "M2", "V2"], ["n2"], name="bn2", epsilon=1e-5),
            h.make_node("Relu", ["n2"], ["r2"], name="relu2"),
            h.make_node("MaxPool", ["r2"], ["p2"], name="pool2", kernel_shape=[2, 2], strides=[2, 2]),
            h.make_node("Reshape", ["p2", "shape"], ["flat"], name="flatten"),
            h.make_node("Gemm", ["flat", "FW", "fb"], ["y"], name="fc"),
        ]
        return nodes, inits, [h.make_tensor_value_info("x", TP.FLOAT, [batch, 1, 28, 28])], \
            [h.make_tensor_value_info("y", TP.FLOAT, [batch, 10])]

    builders = {"mlp": mlp, "cnn": cnn}
    for model in MODELS:
        for batch in BATCHES:
            nodes, inits, inputs, outputs = builders[model](batch)
            graph = h.make_graph(nodes, case_name(model, batch), inputs, outputs, initializer=inits)
            m = h.make_model(graph, opset_imports=[h.make_opsetid("", 13)], ir_version=8)
            onnx.checker.check_model(m)
            name = case_name(model, batch)
            onnx.save(m, os.path.join(d, name + ".onnx"))
            shape = inputs[0].type.tensor_type.shape
            dims = [s.dim_value for s in shape.dim]
            x = np.random.default_rng(1).standard_normal(dims).astype(np.float32)
            x.tofile(os.path.join(d, name + ".in.bin"))
            with open(os.path.join(d, name + ".shape"), "w") as f:
                f.write(",".join(str(v) for v in dims))
    print(f"exported {len(MODELS) * len(BATCHES)} models to {d}")


def timed(fn, runs, warm):
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(runs):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1e3)
    return ts


def write_json(path, backend, ts, extra=None):
    rec = {"backend": backend, "median_ms": statistics.median(ts), "min_ms": min(ts), "runs": len(ts)}
    rec.update(extra or {})
    with open(path, "w") as f:
        json.dump(rec, f)


def cases(d):
    for model in MODELS:
        for batch in BATCHES:
            yield case_name(model, batch)


def read_input(d, name):
    dims = [int(v) for v in open(os.path.join(d, name + ".shape")).read().split(",")]
    x = np.fromfile(os.path.join(d, name + ".in.bin"), dtype=np.float32).reshape(dims)
    return x


def run_ort(d, runs, warm):
    import onnxruntime as ort
    print("onnxruntime", ort.__version__, file=sys.stderr)
    # NFCUOP_TRACE_DIR set: onnxruntime's own profiler writes one Chrome trace-event file per model (one event per node, with
    # its op type); it covers the warm-up runs too.
    trace_dir = os.environ.get("NFCUOP_TRACE_DIR")
    for name in cases(d):
        opts = ort.SessionOptions()
        opts.enable_profiling = bool(trace_dir)
        if trace_dir:
            opts.profile_file_prefix = os.path.join(trace_dir, name + "_ort_profile")   # not the working directory
        sess = ort.InferenceSession(os.path.join(d, name + ".onnx"), sess_options=opts, providers=["CPUExecutionProvider"])
        x = read_input(d, name)
        out = {}

        def f():
            out["y"] = sess.run(None, {"x": x})[0]
        ts = timed(f, runs, warm)
        if trace_dir:
            prof = sess.end_profiling()
            shutil.move(prof, os.path.join(trace_dir, name + ".ort.trace.json"))
        out["y"].astype(np.float32).tofile(os.path.join(d, name + ".ort.bin"))
        write_json(os.path.join(d, name + ".ort.json"), "onnxruntime-cpu", ts,
                   {"version": ort.__version__, "shape": list(out["y"].shape)})
        print(f"ort {name}: median {statistics.median(ts):.3f} ms", file=sys.stderr)


def run_tinygrad(d, runs, warm):
    from tinygrad import Tensor, Device
    from tinygrad.nn.onnx import OnnxRunner
    import tinygrad
    print("tinygrad", getattr(tinygrad, "__version__", "0.14.0"), "device", Device.DEFAULT, file=sys.stderr)
    for name in cases(d):
        runner = OnnxRunner(os.path.join(d, name + ".onnx"))
        x = read_input(d, name)
        out = {}

        def f():
            res = runner({"x": Tensor(x)})
            out["y"] = next(iter(res.values())).numpy()   # numpy() waits for the device, so the time includes the run
        ts = timed(f, runs, warm)
        out["y"].astype(np.float32).tofile(os.path.join(d, name + ".tinygrad.bin"))
        write_json(os.path.join(d, name + ".tinygrad.json"), f"tinygrad-{Device.DEFAULT}", ts,
                   {"shape": list(out["y"].shape)})
        print(f"tinygrad {name}: median {statistics.median(ts):.3f} ms", file=sys.stderr)


def compare(d):
    rows = []
    for name in cases(d):
        ref = np.fromfile(os.path.join(d, name + ".ort.bin"), dtype=np.float32)
        ort_rec = json.load(open(os.path.join(d, name + ".ort.json")))
        rows.append({"case": name, "backend": ort_rec["backend"], "median_ms": ort_rec["median_ms"],
                     "max_abs_err": 0.0, "max_rel_err": 0.0, "status": "reference"})
        for kind in ["tinygrad", "nfcxx"]:
            p = os.path.join(d, name + "." + kind + ".json")
            try:
                rec = json.load(open(p))
            except (OSError, ValueError):   # missing, or empty after a failed run
                rows.append({"case": name, "backend": kind, "status": "not run"})
                continue
            got = np.fromfile(os.path.join(d, name + "." + kind + ".bin"), dtype=np.float32)
            if got.shape != ref.shape:
                rows.append({"case": name, "backend": rec["backend"], "status": "wrong shape"})
                continue
            abs_err = float(np.max(np.abs(got - ref)))
            rel_err = abs_err / max(float(np.max(np.abs(ref))), 1e-30)
            status = "ok" if rel_err <= REL_TOL else "WRONG"
            rows.append({"case": name, "backend": rec["backend"], "median_ms": rec["median_ms"],
                         "max_abs_err": abs_err, "max_rel_err": rel_err, "status": status})
    for r in rows:
        print(json.dumps(r))


def main(argv):
    cmd, d = argv[1], argv[2]
    rest = [int(v) for v in argv[3:5]]
    runs = rest[0] if len(rest) > 0 else 10
    warm = rest[1] if len(rest) > 1 else 3
    if cmd == "export":
        export(d)
    elif cmd == "ort":
        run_ort(d, runs, warm)
    elif cmd == "tinygrad":
        run_tinygrad(d, runs, warm)
    elif cmd == "compare":
        compare(d)
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main(sys.argv)
