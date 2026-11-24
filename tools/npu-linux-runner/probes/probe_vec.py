#!/usr/bin/env python3
"""128-bit vector loads from one base pointer, compiled from C.

Each group g (1024 groups of four floats) sums K vectors src[(g+k) & 1023], lane by lane, in order, and stores the
sum to out[g]. Output is bit-checked against numpy float32 (same order). Marginal cost per vector load is the slope of
p50 against K (the fixed overhead and the per-group store cancel).
"""
import pathlib
import statistics
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import run_kernel as rk  # noqa: E402
import grow_carrier  # noqa: E402

ELEMENTS = 8192
GROUPS = 1024
KS = [1, 16, 64]
BENCH = 60

C_TEMPLATE = """#define NR_ELEMENTS {elements}
#define NR_K {k}
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) {{ return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }}
typedef float v4 __attribute__((ext_vector_type(4)));
void nr_probe_kernel(const u8 *params) {{
    const v4 *src = (const v4 *)pword(params);
    v4 *out = (v4 *)pword(params + 80);
    int g, k;
    for (g = 0; g < {groups}; ++g) {{
        v4 acc = src[g & 1023];
        for (k = 1; k < NR_K; ++k) {{
            v4 t = src[(g + k) & 1023];
            acc = acc + t;
        }}
        out[g] = acc;
    }}
}}
"""


def expected(x, k):
    src = x.reshape(GROUPS, 4).astype(np.float32)
    acc = src.copy()
    for j in range(1, k):
        acc = (acc + np.roll(src, -j, axis=0)).astype(np.float32)
    return acc.reshape(-1)


def main():
    import openvino as ov
    movi, wine_host = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wine = rk.Wine(movi, wine_host)
    work = pathlib.Path("probe-vec").resolve()
    work.mkdir(exist_ok=True)
    base = rk.base_blob(ELEMENTS, work).read_bytes()
    core = ov.Core()
    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, ELEMENTS // 2).astype(np.float32)
    feed = np.ascontiguousarray(x.view(np.float16))
    results = {}
    for k in KS:
        sub = work / f"k{k}"
        sub.mkdir(exist_ok=True)
        src = sub / "kernel.c"
        src.write_text(C_TEMPLATE.format(elements=ELEMENTS, k=k, groups=GROUPS))
        text, hazards = rk.build_text(src, "nr_probe_kernel", sub, wine, movi)
        blob, _ = grow_carrier.grow(base, 1 << 18)
        off, size = rk.section(blob, "shave.text")
        if len(text) > size:
            raise SystemExit(f"k={k}: text {len(text)} exceeds window {size}")
        patched = bytearray(blob)
        patched[off:off + size] = text + bytes(size - len(text))
        req = core.import_model(bytes(patched), "NPU").create_infer_request()
        got = np.ascontiguousarray(next(iter(req.infer({0: feed}).values()))).view(np.uint32)
        want = expected(x, k).view(np.uint32)
        bad = int(np.count_nonzero(got[:len(want)] != want))
        for _ in range(5):
            req.infer({0: feed})
        ts = []
        for _ in range(BENCH):
            t = time.perf_counter(); req.infer({0: feed}); ts.append((time.perf_counter() - t) * 1e3)
        ts.sort()
        p50 = statistics.median(ts)
        results[k] = p50
        print(f"K {k:3d} text {len(text):6d} B hazard-NOPs {hazards:4d} bit-mismatch {bad:5d}/{len(want)}  p50 {p50:8.3f} ms", flush=True)
    a, b = KS[0], KS[-1]
    slope = (results[b] - results[a]) / ((b - a) * GROUPS)
    print(f"marginal cost per 128-bit load (with its lane add): {slope * 1e6:8.2f} ns", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
