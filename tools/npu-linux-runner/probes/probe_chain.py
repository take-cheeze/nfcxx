#!/usr/bin/env python3
"""Measure SHAVE per-operation cost: a serial dependent chain vs four interleaved chains, at several chain lengths.

Per-op cost = slope of p50 time against total operations (words * NR_ITER * 2 ops). The fixed inference
overhead is the intercept and cancels in the slope.
"""
import pathlib
import statistics
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import run_kernel as rk  # noqa: E402

ELEMENTS = 8192
WORDS = ELEMENTS // 2
ITERS = [128, 256, 512]
BENCH = 60
SRC = {"serial": HERE / "chain_serial.c", "par4": HERE / "chain_par4.c"}


def expected(words_in, iters):
    x = words_in.copy()
    for _ in range(iters):
        x = (x * np.uint32(3) + np.uint32(7)).astype(np.uint32)
    return x


def main():
    import openvino as ov
    work = pathlib.Path("probe-chain").resolve()
    work.mkdir(exist_ok=True)
    wine = rk.Wine(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    base = rk.base_blob(ELEMENTS, work).read_bytes()
    off, size = rk.section(base, "shave.text")
    core = ov.Core()
    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, ELEMENTS).astype(np.float16)
    words_in = x.view(np.uint32)
    results = {}
    for name, src in SRC.items():
        for iters in ITERS:
            sub = work / f"{name}_{iters}"
            sub.mkdir(exist_ok=True)
            kernel = sub / "kernel.c"
            kernel.write_text(f"#define NR_ELEMENTS {ELEMENTS}\n#define NR_ITER {iters}\n" + src.read_text())
            text, hazards = rk.build_text(kernel, "nr_probe_kernel", sub, wine, pathlib.Path(sys.argv[1]))
            if len(text) > size:
                raise SystemExit(f"{name} {iters}: text {len(text)} exceeds shave.text {size}")
            patched = bytearray(base)
            patched[off:off + size] = text + bytes(size - len(text))
            req = core.import_model(bytes(patched), "NPU").create_infer_request()
            out = np.ascontiguousarray(next(iter(req.infer({0: x}).values()))).view(np.uint32)
            bad = int(np.count_nonzero(out != expected(words_in, iters)))
            for _ in range(10):
                req.infer({0: x})
            ts = []
            for _ in range(BENCH):
                t = time.perf_counter(); req.infer({0: x}); ts.append((time.perf_counter() - t) * 1e3)
            ts.sort()
            p50 = statistics.median(ts)
            results[(name, iters)] = p50
            print(f"{name:6s} iters {iters:4d} text {len(text):6d} B hazards {hazards:4d} "
                  f"mismatch {bad:5d}  p50 {p50:8.3f} ms  min {ts[0]:8.3f} ms", flush=True)
    ops = WORDS * 2
    for name in SRC:
        a, b = ITERS[0], ITERS[-1]
        slope = (results[(name, b)] - results[(name, a)]) / ((b - a) * WORDS)
        print(f"{name:6s} marginal cost {slope * 1e6:8.3f} ns per word-step ({slope * 1e6 / 2:.3f} ns per op, 2 ops/step)", flush=True)
    print(f"intercept (fixed overhead) serial {results[('serial', ITERS[0])] - (results[('serial', ITERS[-1])] - results[('serial', ITERS[0])]) / (ITERS[-1] - ITERS[0]) * ITERS[0]:.3f} ms", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
