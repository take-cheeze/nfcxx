#!/usr/bin/env python3
"""Compare two SHAVE kernels that compute the same function, on the NPU, from Linux.

Each kernel is built with the same pinned toolchain, patched into the same base blob, run on the NPU,
checked word for word against numpy, and timed. The timing covers one OpenVINO inference (copy in,
run the kernel, copy out), so it includes fixed overhead as well as kernel time.

  python3 bench_kernels.py examples/bench_lanes.c examples/bench_vector.c \
      --movi-root ~/movitools/MVC_DEPEND --wine-host host --elements 8192 --bench 200
"""
import argparse
import pathlib
import statistics
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_kernel as rk  # noqa: E402


def with_defines(source, elements, repeat, work):
    """Copy the kernel with NR_ELEMENTS and NR_REPEAT defined; the pinned compile flags cannot pass -D."""
    text = source.read_text()
    out = work / ("kernel_" + source.stem + ".c")
    out.write_text(f"#define NR_ELEMENTS {elements}\n#define NR_REPEAT {repeat}\n" + text)
    return out


def run_one(source, elements, repeat, base, work, wine, movi_root, bench, x, expected_words):
    kernel_c = with_defines(source, elements, repeat, work)
    text, hazards = rk.build_text(kernel_c, "nr_probe_kernel", work, wine, movi_root)
    off, size = rk.section(base, "shave.text")
    if len(text) > size:
        raise SystemExit(f"{source.name}: text {len(text)} bytes exceeds shave.text {size}")
    patched = bytearray(base)
    patched[off : off + size] = text + bytes(size - len(text))

    import openvino as ov

    request = ov.Core().import_model(bytes(patched), "NPU").create_infer_request()
    out = next(iter(request.infer({0: x}).values()))
    got = np.ascontiguousarray(out).view(np.uint32)
    mismatches = int(np.count_nonzero(got != expected_words))
    result = {"kernel": source.name, "repeat": repeat, "text_bytes": len(text), "hazard_nops": hazards,
              "mismatched_words": mismatches, "words": got.size}
    if bench:
        for _ in range(20):
            request.infer({0: x})
        times = []
        for _ in range(bench):
            t = time.perf_counter()
            request.infer({0: x})
            times.append((time.perf_counter() - t) * 1e3)
        times.sort()
        result.update(p50=statistics.median(times), p90=times[int(0.9 * len(times))], min=times[0])
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("kernels", nargs=2, type=pathlib.Path)
    p.add_argument("--movi-root", type=pathlib.Path, required=True)
    p.add_argument("--wine-host", type=pathlib.Path, required=True)
    p.add_argument("--elements", type=int, default=8192, help="FP16 elements (even, multiple of 8)")
    p.add_argument("--bench", type=int, default=200)
    p.add_argument("--repeat", type=int, default=1, help="passes over the data inside one inference")
    p.add_argument("--work", type=pathlib.Path, default=pathlib.Path("npu-bench"))
    p.add_argument("--window", type=int, default=0, help="grow the code window (bytes); 0 keeps the exported size")
    args = p.parse_args()
    if args.elements % 8:
        raise SystemExit("--elements must be a multiple of 8")

    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    wine = rk.Wine(args.movi_root, args.wine_host)
    base = rk.base_blob(args.elements, work).read_bytes()
    if args.window:
        base, _ = rk.grow_carrier.grow(base, args.window)

    rng = np.random.default_rng(1)
    x = rng.uniform(-2, 2, args.elements).astype(np.float16)
    words = x.view(np.uint32)
    expected = (words * np.uint32(3) + np.uint32(7)).astype(np.uint32)

    results = []
    for src in args.kernels:
        sub = work / src.stem
        sub.mkdir(exist_ok=True)
        results.append(run_one(src.resolve(), args.elements, args.repeat, base, sub, wine, args.movi_root,
                               args.bench, x, expected))
    for r in results:
        status = "PASS" if r["mismatched_words"] == 0 else f"FAIL ({r['mismatched_words']} words)"
        line = f"{r['kernel']:20s} repeat {r['repeat']:4d}  text {r['text_bytes']:6d} B  hazards {r['hazard_nops']}  check {status}"
        if "p50" in r:
            line += f"  p50 {r['p50']:.3f} ms  p90 {r['p90']:.3f} ms  min {r['min']:.3f} ms"
        print(line, flush=True)
    if any(r["mismatched_words"] for r in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
