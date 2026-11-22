#!/usr/bin/env python3
"""Straight-line compare and select cost, compiled from C (ext-vector 128-bit loads, unrolled steps).

Per group g (1024 groups of four floats), K unrolled steps:
  base:  acc = acc + src[(g+k)&1023]
  cmp:   the same, then lane 0 selects the larger of acc and t:  acc[0] = (acc[0] > t[0]) ? acc[0] : t[0]
Output is bit-checked against numpy float32 in the same order.
Marginal cost per step = (p50 at K=16 minus p50 at K=1) / (15 * 1024).
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
BENCH = 60

HEAD = """#define NR_ELEMENTS {elements}
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) {{ return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }}
typedef float v4 __attribute__((ext_vector_type(4)));
void nr_probe_kernel(const u8 *params) {{
    const v4 *src = (const v4 *)pword(params);
    v4 *out = (v4 *)pword(params + 80);
    int g;
    for (g = 0; g < {groups}; ++g) {{
        v4 acc = src[g & 1023];
"""


def c_source(variant, k):
    lines = [HEAD.format(elements=ELEMENTS, groups=GROUPS)]
    for j in range(1, k):
        lines.append(f"        v4 t{j} = src[(g + {j}) & 1023];\n")
        lines.append(f"        acc = acc + t{j};\n")
        if variant == "cmp":
            lines.append(f"        acc[0] = (acc[0] > t{j}[0]) ? acc[0] : t{j}[0];\n")
    lines.append("        out[g] = acc;\n    }\n}\n")
    return "".join(lines)


def expected(x, variant, k):
    f = np.float32
    src = x.reshape(GROUPS, 4).astype(np.float32)
    acc = src.copy()
    for j in range(1, k):
        t = np.roll(src, -j, axis=0)
        acc = (acc + t).astype(np.float32)
        if variant == "cmp":
            acc[:, 0] = np.where(acc[:, 0] > t[:, 0], acc[:, 0], t[:, 0]).astype(np.float32)
    return acc.reshape(-1)


def main():
    import openvino as ov
    movi, wine_host = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wine = rk.Wine(movi, wine_host)
    work = pathlib.Path("probe-cmp").resolve()
    work.mkdir(exist_ok=True)
    base = rk.base_blob(ELEMENTS, work).read_bytes()
    core = ov.Core()
    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, ELEMENTS // 2).astype(np.float32)
    feed = np.ascontiguousarray(x.view(np.float16))
    results = {}
    for variant in ["base", "cmp"]:
        for k in [1, 16]:
            sub = work / f"{variant}_{k}"
            sub.mkdir(exist_ok=True)
            src = sub / "kernel.c"
            src.write_text(c_source(variant, k))
            text, hazards = rk.build_text(src, "nr_probe_kernel", sub, wine, movi)
            blob, _ = grow_carrier.grow(base, 1 << 18)
            off, size = rk.section(blob, "shave.text")
            if len(text) > size:
                raise SystemExit(f"{variant} {k}: text {len(text)} exceeds window {size}")
            patched = bytearray(blob)
            patched[off:off + size] = text + bytes(size - len(text))
            req = core.import_model(bytes(patched), "NPU").create_infer_request()
            got = np.ascontiguousarray(next(iter(req.infer({0: feed}).values()))).view(np.uint32)
            want = expected(x, variant, k).view(np.uint32)
            bad = int(np.count_nonzero(got[:len(want)] != want))
            for _ in range(5):
                req.infer({0: feed})
            ts = []
            for _ in range(BENCH):
                t = time.perf_counter(); req.infer({0: feed}); ts.append((time.perf_counter() - t) * 1e3)
            ts.sort()
            p50 = statistics.median(ts)
            results[(variant, k)] = p50
            print(f"{variant:4s} K {k:3d} text {len(text):6d} B hazard-NOPs {hazards:4d} bit-mismatch {bad:5d}/{len(want)}  p50 {p50:8.3f} ms", flush=True)
    for variant in ["base", "cmp"]:
        slope = (results[(variant, 16)] - results[(variant, 1)]) / (15 * GROUPS)
        print(f"{variant:4s} marginal cost per step: {slope * 1e6:8.2f} ns", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
