#!/usr/bin/env python3
"""Run npu-render's emitted frame fixtures on the NPU and compare each output with the host reference, bit for bit.

The fixture file comes from npu-render's frame_kernel_test --fixtures (format NRFFIX01: header, then per fixture a
name, the input span and the expected span, both frame::span_bytes = 264192 bytes). Each fixture is a full span:
the captured DWM shader programs with their windows and background. The renderer is compiled from the same
frame_core.h and frame_programs.h the fixtures were rendered with.

usage: fixtures_check.py <fixtures.bin> <ptl_kernels dir> --movi-root DIR --wine-host DIR [--work DIR]
           [--only SUBSTRING] [--time N] [--lowered]
"""
import argparse
import pathlib
import statistics
import struct
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import grow_carrier  # noqa: E402
import run_kernel as rk  # noqa: E402
from flat_dispatch import flatten  # noqa: E402
from flat_vertex import flatten_vertex  # noqa: E402
from gen_frame_fill import ENTRY, inline  # noqa: E402

SPAN = 264192
ELEMENTS = SPAN // 2
HALF = SPAN // 2
# output header of a rejected frame: NR_FRAME_OUTPUT_MAGIC, then NR_STATUS_HEADER (1)
HEADER_REJECTED = struct.pack('<2I', 0x4E52464F, 1)


def read_fixtures(path):
    data = open(path, "rb").read()
    if data[:8] != b"NRFFIX01":
        raise SystemExit("not a NRFFIX01 fixture file")
    version, count, span = struct.unpack_from("<IIQ", data, 8)
    if span != SPAN:
        raise SystemExit(f"span {span} differs from {SPAN}")
    at = 24
    for _ in range(count):
        (name_len,) = struct.unpack_from("<I", data, at)
        at += 4
        name = data[at : at + name_len].decode("ascii", "replace")
        at += name_len
        at = (at + 3) & ~3
        inp = data[at : at + SPAN]
        at += SPAN
        exp = data[at : at + SPAN]
        at += SPAN
        yield name, inp, exp


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("fixtures", type=pathlib.Path)
    p.add_argument("kernels", type=pathlib.Path)
    p.add_argument("--movi-root", type=pathlib.Path, required=True)
    p.add_argument("--wine-host", type=pathlib.Path, required=True)
    p.add_argument("--work", type=pathlib.Path, default=pathlib.Path("npu-fixtures"))
    p.add_argument("--only", default="", help="run fixtures whose name contains this")
    p.add_argument("--time", type=int, default=0, help="time each matching fixture with this many inferences")
    p.add_argument("--loop-fixpoint", action="store_true", help="apply the loop fixed-point transform")
    args = p.parse_args()

    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    wine = rk.Wine(args.movi_root, args.wine_host)
    base, _ = grow_carrier.grow(rk.base_blob(ELEMENTS, work).read_bytes(), 262144)
    core = flatten_vertex(flatten(inline(args.kernels / "frame_core.h")))   # both native trees flattened
    if args.loop_fixpoint:
        from loop_fixpoint import loop_fixpoint
        core = loop_fixpoint(core)
    (work / "frame_fill_entry.c").write_text(core + ENTRY)
    text, hazards = rk.build_text(work / "frame_fill_entry.c", "nr_probe_kernel", work, wine, args.movi_root)
    off, size = rk.section(base, "shave.text")
    patched = bytearray(base)
    patched[off : off + size] = text + bytes(size - len(text))
    print(f"renderer text {len(text)} bytes, hazard nops {hazards}", flush=True)

    import openvino as ov

    core_ov = ov.Core()

    def load():
        return core_ov.import_model(bytes(patched), "NPU").create_infer_request()

    request = load()
    passed = failed = exact = 0
    failures, timings = [], []
    for name, inp, exp in read_fixtures(args.fixtures):
        if args.only and args.only not in name:
            continue
        x = np.frombuffer(inp, dtype=np.float16).copy()
        try:
            out = np.ascontiguousarray(next(iter(request.infer({0: x}).values()))).view(np.uint8).tobytes()
        except Exception as e:  # device error: note it and reload the model for the next fixture
            failed += 1
            failures.append((name, f"device error: {str(e)[:80]}"))
            request = load()
            continue
        # The blob has two shave invocations. The second runs on the upper half of the buffers, where there is no
        # frame: it writes only a rejected header (NRFO, status 1). Compare the first half exactly; the upper half
        # must hold that header and zeros.
        got = np.frombuffer(out[:HALF], dtype=np.uint8).astype(np.int16)
        want = np.frombuffer(exp[:HALF], dtype=np.uint8).astype(np.int16)
        delta = np.abs(got - want)
        tail = out[HALF:]
        tail_ok = tail[:8] == HEADER_REJECTED and not any(tail[8:])
        worst = int(delta.max())
        if worst == 0:
            exact += 1
        if worst <= 1 and tail_ok:
            passed += 1
        else:
            failed += 1
            failures.append((name, f"max byte delta {worst}, {int(np.count_nonzero(delta))} bytes differ"
                                   + ("" if tail_ok else ", tail unexpected")))
        if args.time:
            for _ in range(5):
                request.infer({0: x})
            ts = []
            for _ in range(args.time):
                t = time.perf_counter()
                request.infer({0: x})
                ts.append((time.perf_counter() - t) * 1e3)
            timings.append((statistics.median(ts), name))
    print(f"fixtures: {passed} within one byte, {failed} worse; {exact} bit-exact", flush=True)
    import collections
    by_kind = collections.Counter((n.split("-")[0], "exact" if False else "fail") for n, _ in failures)
    for kind, count in sorted(by_kind.items()):
        print(f"  {kind[0]}: {count} not exact", flush=True)
    for name, why in failures:
        print(f"  FAIL {name}: {why}")
    for ms, name in sorted(timings, reverse=True)[:25]:
        print(f"  time p50 {ms:8.3f} ms  {name}")


if __name__ == "__main__":
    main()
