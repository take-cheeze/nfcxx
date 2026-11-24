#!/usr/bin/env python3
"""Run npu-render's frame renderer (frame_core.h, fill commands) on the NPU from Linux, check the tile, time it.

The renderer comes from an npu-render checkout (its native/windows/ptl_kernels directory is read at build
time and is not copied into this repository). Generate the batch first:

  python3 frame/gen_frame_fill.py <npu-render>/native/windows/ptl_kernels <work>/fill 1 64
  python3 frame/frame_check.py <work>/fill --npu-render-kernels ... (see --help)
"""
import argparse
import pathlib
import statistics
import struct
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import grow_carrier  # noqa: E402
import run_kernel as rk  # noqa: E402

SPAN = 132096  # FP16 elements in one frame plane (NR_FRAME_SPAN bytes / 2)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("batch", type=pathlib.Path, help="directory written by gen_frame_fill.py")
    p.add_argument("--movi-root", type=pathlib.Path, required=True)
    p.add_argument("--wine-host", type=pathlib.Path, required=True)
    p.add_argument("--work", type=pathlib.Path, default=pathlib.Path("npu-frame"))
    p.add_argument("--window", type=int, default=262144)
    p.add_argument("--bench", type=int, default=0)
    args = p.parse_args()

    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    wine = rk.Wine(args.movi_root, args.wine_host)
    base = rk.base_blob(SPAN, work).read_bytes()
    base, _ = grow_carrier.grow(base, args.window)
    text, hazards = rk.build_text(args.batch / "frame_fill_entry.c", "nr_probe_kernel", work, wine, args.movi_root)
    off, size = rk.section(base, "shave.text")
    if len(text) > size:
        raise SystemExit(f"text {len(text)} bytes exceeds window {size}")
    patched = bytearray(base)
    patched[off : off + size] = text + bytes(size - len(text))
    print(f"frame kernel text {len(text)} bytes, hazard nops {hazards}, window {size}", flush=True)

    data = np.load(args.batch / "frame_input.npy")
    expected = np.load(args.batch / "frame_expected.npy")
    commands = struct.unpack_from("<I", data.view(np.uint8).tobytes(), 28)[0]
    import openvino as ov

    request = ov.Core().import_model(bytes(patched), "NPU").create_infer_request()
    out = np.ascontiguousarray(next(iter(request.infer({0: data}).values()))).view(np.uint8)
    magic, status, executed = struct.unpack_from("<3I", out.tobytes(), 0)
    covered = struct.unpack_from("<I", out.tobytes(), 12)[0]
    tile = out[64 : 64 + expected.size]
    bad = int(np.count_nonzero(tile != expected))
    ok = bad == 0 and status == 0 and executed == commands and magic == 0x4E52464F
    print(f"status {status} executed {executed}/{commands} covered {covered} tile mismatches {bad}/{expected.size}",
          "PASS" if ok else "FAIL", flush=True)
    if args.bench:
        for _ in range(10):
            request.infer({0: data})
        times = []
        for _ in range(args.bench):
            t = time.perf_counter()
            request.infer({0: data})
            times.append((time.perf_counter() - t) * 1e3)
        times.sort()
        print(f"bench {args.bench}: p50 {statistics.median(times):.3f} ms  p90 {times[int(0.9 * len(times))]:.3f} ms"
              f"  min {times[0]:.3f} ms", flush=True)
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
