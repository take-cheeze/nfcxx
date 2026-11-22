#!/usr/bin/env python3
"""Float32 version of probe_chain.py: serial dependent chain vs four interleaved chains (x = x*0.75 + 0.5).

Results are compared bit for bit with numpy float32 (same operation order). Marginal cost is the slope of p50
time against chain length; the fixed overhead cancels out.
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
SRC = {"fserial": HERE / "chain_fserial.c", "fpar4": HERE / "chain_fpar4.c"}


def expected(x, iters):
    x = x.copy()
    for _ in range(iters):
        x = (x * np.float32(0.75) + np.float32(0.5)).astype(np.float32)
    return x


def main():
    import openvino as ov
    movi, wine_host = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    work = pathlib.Path("probe-float").resolve()
    work.mkdir(exist_ok=True)
    wine = rk.Wine(movi, wine_host)
    base = rk.base_blob(ELEMENTS, work).read_bytes()
    off, size = rk.section(base, "shave.text")
    core = ov.Core()
    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, WORDS).astype(np.float32)
    feed = np.ascontiguousarray(x.view(np.float16))
    results = {}
    for name, src in SRC.items():
        for iters in ITERS:
            sub = work / f"{name}_{iters}"
            sub.mkdir(exist_ok=True)
            kernel = sub / "kernel.c"
            kernel.write_text(f"#define NR_ELEMENTS {ELEMENTS}\n#define NR_ITER {iters}\n" + src.read_text())
            text, hazards = rk.build_text(kernel, "nr_probe_kernel", sub, wine, movi)
            if len(text) > size:
                raise SystemExit(f"{name} {iters}: text {len(text)} exceeds shave.text {size}")
            patched = bytearray(base)
            patched[off:off + size] = text + bytes(size - len(text))
            req = core.import_model(bytes(patched), "NPU").create_infer_request()
            got = np.ascontiguousarray(next(iter(req.infer({0: feed}).values()))).view(np.uint32)
            want = expected(x, iters).view(np.uint32)
            bad = int(np.count_nonzero(got != want))
            for _ in range(10):
                req.infer({0: feed})
            ts = []
            for _ in range(BENCH):
                t = time.perf_counter(); req.infer({0: feed}); ts.append((time.perf_counter() - t) * 1e3)
            ts.sort()
            p50 = statistics.median(ts)
            results[(name, iters)] = p50
            print(f"{name:7s} iters {iters:4d} text {len(text):6d} B hazards {hazards:4d} "
                  f"bit-mismatch {bad:5d}/{WORDS}  p50 {p50:8.3f} ms  min {ts[0]:8.3f} ms", flush=True)
    for name in SRC:
        a, b = ITERS[0], ITERS[-1]
        slope = (results[(name, b)] - results[(name, a)]) / ((b - a) * WORDS)
        print(f"{name:7s} marginal cost {slope * 1e6:8.3f} ns per word-step (one mul + one add)", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
