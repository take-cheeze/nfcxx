#!/usr/bin/env python3
"""Straight-line float statements compiled from C (the compiler places hazard NOPs). Coefficients sum to 1 so values do not underflow, timed on the NPU.

Each statement is  v[d] = v[a]*0.5f + v[b]*0.5f  over 16 float locals, unrolled inside the per-word loop.
Variants set the dependence pattern:
  chain  a = t-1            (every statement depends on the one before: fully serial)
  wide   a = t-8, b = t-5   (dependences reach back 5-8 statements: wide)
Output is bit-checked against numpy float32 with the same statement order.
Marginal cost = slope of p50 against statement count (fixed overhead cancels).
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
WORDS = ELEMENTS // 2
COUNTS = [100, 400, 1000]
BENCH = 40
NV = 16
VARIANTS = [v for v in (sys.argv[3].split(",") if len(sys.argv) > 3 else ["chain", "wide"])]


def statements(variant, m):
    out = []
    variant = variant.replace("_mem", "").replace("_gload", "")
    for t in range(m):
        d = t % NV
        if variant == "chain":
            a, b = (t - 1) % NV, (t - 2) % NV
        else:
            a, b = (t - 8) % NV, (t - 5) % NV
        out.append((d, a, b))
    return out


def c_source(variant, m):
    body = []
    mem = variant.endswith("_mem")
    for t, (d, a, b) in enumerate(statements(variant, m)):
        body.append(f"        v{d} = v{a} * 0.5f + v{b} * 0.5f;")
        if variant.endswith("_gload"):
            # a load from the kernel's input array (parameter memory), added as an exact zero
            body.append(f"        v{d} = v{d} + in[(i + {t}) & 4095] * 0.0f;")
        if mem:
            # round trip through a local array at a runtime index: same value, real load and store
            body.append(f"        buf[(i + {t}) & 63] = v{d};")
            body.append(f"        v{d} = buf[(i + {t}) & 63];")
    init = " ".join(f"float v{k} = x * {k + 1}.0f;" for k in range(NV))
    summ = " + ".join(f"v{k}" for k in range(NV))
    return f"""#define NR_ELEMENTS {ELEMENTS}
typedef unsigned int u32;
typedef unsigned char u8;
static u32 pword(const u8 *p) {{ return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }}
void nr_probe_kernel(const u8 *params) {{
    const float *in = (const float *)pword(params);
    float *out = (float *)pword(params + 80);
    const int words = NR_ELEMENTS / 2;
    int i;
    for (i = 0; i < words; ++i) {{
        float x = in[i];
        volatile float buf[64];
        {init}
{chr(10).join(body)}
        out[i] = {summ};
    }}
}}
"""


def expected(x, variant, m):
    f = np.float32
    res = np.empty(WORDS, np.float32)
    for i in range(WORDS):
        xi = f(x[i])
        v = [xi * f(k + 1) for k in range(NV)]
        for t, (d, a, b) in enumerate(statements(variant, m)):
            v[d] = f(v[a] * f(0.5) + v[b] * f(0.5))
            if variant.endswith("_gload"):
                v[d] = f(v[d] + f(x[(i + t) & 4095] * f(0)))
        s = v[0]
        for k in range(1, NV):
            s = f(s + v[k])
        res[i] = s
    return res


def main():
    import openvino as ov
    movi, wine_host = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wine = rk.Wine(movi, wine_host)
    work = pathlib.Path("probe-synth").resolve()
    work.mkdir(exist_ok=True)
    base = rk.base_blob(ELEMENTS, work).read_bytes()
    core = ov.Core()
    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, WORDS).astype(np.float32)
    feed = np.ascontiguousarray(x.view(np.float16))
    results = {}
    for variant in VARIANTS:
        for m in COUNTS:
            sub = work / f"{variant}_{m}"
            sub.mkdir(exist_ok=True)
            src = sub / "kernel.c"
            src.write_text(c_source(variant, m))
            text, hazards = rk.build_text(src, "nr_probe_kernel", sub, wine, movi)
            blob, _ = grow_carrier.grow(base, 1 << 18)
            off, size = rk.section(blob, "shave.text")
            if len(text) > size:
                raise SystemExit(f"{variant} {m}: text {len(text)} exceeds window {size}")
            patched = bytearray(blob)
            patched[off:off + size] = text + bytes(size - len(text))
            req = core.import_model(bytes(patched), "NPU").create_infer_request()
            got = np.ascontiguousarray(next(iter(req.infer({0: feed}).values()))).view(np.uint32)
            want = expected(x, variant, m).view(np.uint32)
            bad = int(np.count_nonzero(got[:WORDS] != want))
            for _ in range(5):
                req.infer({0: feed})
            ts = []
            for _ in range(BENCH):
                t = time.perf_counter(); req.infer({0: feed}); ts.append((time.perf_counter() - t) * 1e3)
            ts.sort()
            p50 = statistics.median(ts)
            results[(variant, m)] = p50
            print(f"{variant:5s} statements {m:5d} text {len(text):6d} B hazard-NOPs {hazards:4d} "
                  f"bit-mismatch {bad:5d}/{WORDS}  p50 {p50:8.3f} ms", flush=True)
    for variant in VARIANTS:
        a, b = COUNTS[0], COUNTS[-1]
        slope = (results[(variant, b)] - results[(variant, a)]) / ((b - a) * WORDS)
        print(f"{variant:5s} marginal cost {slope * 1e6:8.2f} ns per statement (2 mul + 1 add)", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    main()
