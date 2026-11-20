#!/usr/bin/env python3
"""Run a SHAVE kernel on an Intel NPU from Linux, experimentally.

Pipeline (each step is a file the next step reads, so a failure names its step):

  1. export an FP16 add model as an NPU blob with OpenVINO (the base carrier);
  2. compile the kernel with the pinned MoviTools toolchain through wine (npubuild.c),
     fix write-port hazards (hazards.fix_hazards, copied from npu-render), and link with the pinned SHAVE script;
  3. replace the carrier's shave.text section with the kernel's text (same contract the Windows
     carrier path checks in npu-render's ptl_carrier.py, except the invocation count, see below);
  4. import the patched blob into OpenVINO on the NPU, run it, and check the output.

Experimental: this route is not the qualified Windows route (npu-render's ptl_carrier.py says so too). The
exported add blob has two task.shave invocations; the qualified carrier has six, so only the
execution behaviour is tested here, not the qualified contract.

Requirements: OpenVINO with the NPU plugin, MoviTools (moviCompile64.dll, moviAsm64.dll,
moviLLD64.dll) in <movi-root>/bin, wine, and npubuild.exe built from npubuild.c in <wine-host>.

Example:
  python3 run_kernel.py examples/fill.c --movi-root ~/movitools/MVC_DEPEND \
      --wine-host ~/npu-linux-runner/host --elements 8 --expect 1.5 --bench 300
"""
import argparse
import importlib.util
import os
import pathlib
import statistics
import struct
import subprocess
import sys
import time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import hazards  # noqa: E402  (fix_hazards and read_kernel_text, copied from npu-render)
import grow_carrier  # noqa: E402  (grows shave.text of an exported blob, as npu-render's grow tool does)


def wine_path(path):
    """Windows-style path that wine maps back to the Linux path (Z: is the unix root)."""
    return "Z:" + str(pathlib.Path(path).resolve()).replace("/", "\\")


def base_blob(elements, out_dir):
    import io
    import openvino as ov
    from openvino import opset13 as op

    x = op.parameter([elements], np.float16, name="x")
    y = op.add(x, op.constant(np.float16(1.0)))
    compiled = ov.Core().compile_model(ov.Model([y], [x], "add1"), "NPU")
    buf = io.BytesIO()
    compiled.export_model(buf)
    path = out_dir / f"base_{elements}.blob"
    path.write_bytes(buf.getvalue())
    return path


def section(blob, name):
    h = struct.unpack_from("<16sHHIQQQIHHHHHH", blob)
    raw = [struct.unpack_from("<IIQQQQIIQQ", blob, h[6] + i * 64) for i in range(h[12])]
    names = blob[raw[h[13]][4] : raw[h[13]][4] + raw[h[13]][5]]
    for s in raw:
        if names[s[0] : names.find(b"\0", s[0])] == name.encode():
            return s[4], s[5]
    raise ValueError(f"section {name} not found")


class Wine:
    def __init__(self, movi_root, wine_host):
        self.root = movi_root
        self.host = pathlib.Path(wine_host)
        self.env = dict(os.environ, WINEDEBUG="-all")

    def run(self, mode, *args):
        return subprocess.run(
            ["wine", str(self.host / "npubuild.exe"), mode, wine_path(self.root), *args],
            env=self.env,
            capture_output=True,
            timeout=600,
        )


def compile_kernel(source, work, wine):
    asm_path = work / "kernel.s"
    diag = work / "compile.log"
    r = wine.run("compile", wine_path(source), wine_path(asm_path), wine_path(diag))
    if r.returncode or not asm_path.exists():
        detail = diag.read_text(errors="replace")[-400:] if diag.exists() else r.stdout.decode(errors="replace")[-400:]
        raise RuntimeError("compile failed: " + detail)
    return asm_path.read_bytes()


def run_assemble(assembly, root, wine, work):
    (work / "in.s").write_bytes(assembly)
    for f in ("out.o", "diag.txt"):
        if (work / f).exists():
            (work / f).unlink()
    r = wine.run("asm", wine_path(work / "in.s"), wine_path(work / "out.o"), wine_path(work / "diag.txt"))
    diag = (work / "diag.txt").read_bytes() if (work / "diag.txt").exists() else b""
    obj = (work / "out.o").read_bytes() if (work / "out.o").exists() else b""
    return r.returncode, diag, obj


def build_text(source, entry, work, wine, movi_root):
    """Compile, fix hazards, assemble and link; return the kernel's SHAVE text bytes."""
    assembly = compile_kernel(source, work, wine)

    def transform(root, source_bytes, output, assemble=False, strict=True):
        if not assemble:
            raise RuntimeError("compile happens once, before hazard fixing")
        code, diag, obj = run_assemble(source_bytes, root, wine, work)
        if not strict:
            return code, diag, obj if code == 0 else b""
        if code:
            raise RuntimeError("assemble failed: " + diag.decode(errors="replace")[:500])
        return obj

    hazards.transform = transform
    assembly, sites = hazards.fix_hazards(pathlib.Path(movi_root), assembly, work)
    obj = transform(movi_root, assembly, work, assemble=True, strict=True)
    (work / "obj.o").write_bytes(obj)
    (work / "link.elf").unlink(missing_ok=True)
    r = wine.run("link", wine_path(work / "obj.o"), wine_path(work / "link.elf"), entry)
    if r.returncode or not (work / "link.elf").exists():
        raise RuntimeError("link failed: " + r.stdout.decode(errors="replace")[-400:])
    elf = (work / "link.elf").read_bytes()
    return hazards.read_kernel_text(elf), len(sites)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("kernel", type=pathlib.Path, help="C source of the kernel")
    p.add_argument("--entry", default="nr_probe_kernel")
    p.add_argument("--movi-root", type=pathlib.Path, required=True)
    p.add_argument("--wine-host", type=pathlib.Path, required=True, help="directory holding npubuild.exe")
    p.add_argument("--elements", type=int, default=8, help="FP16 elements of the base add model")
    p.add_argument("--expect", type=float, help="every output element must equal this value")
    p.add_argument("--bench", type=int, default=0, help="inferences to time after the check")
    p.add_argument("--window", type=int, default=0,
                   help="grow the code window to this many bytes (1 KiB multiple); 0 keeps the exported size")
    p.add_argument("--work", type=pathlib.Path, default=pathlib.Path("npu-linux-run"))
    args = p.parse_args()

    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    wine = Wine(args.movi_root, args.wine_host)

    base = base_blob(args.elements, work).read_bytes()
    if args.window:
        base, _ = grow_carrier.grow(base, args.window)
    text_off, text_size = section(base, "shave.text")
    text, hazards = build_text(args.kernel, args.entry, work, wine, args.movi_root)
    if len(text) > text_size:
        raise SystemExit(f"kernel text {len(text)} bytes exceeds shave.text {text_size}")
    patched = bytearray(base)
    patched[text_off : text_off + text_size] = text + bytes(text_size - len(text))
    (work / "patched.blob").write_bytes(bytes(patched))
    print(f"kernel text {len(text)} bytes, hazard nops {hazards}, shave.text {text_size} bytes", flush=True)

    import openvino as ov

    core = ov.Core()
    x = np.arange(args.elements, dtype=np.float16)
    request = core.import_model(bytes(patched), "NPU").create_infer_request()
    out = next(iter(request.infer({0: x}).values()))
    print("input ", x)
    print("output", out, flush=True)
    if args.expect is not None:
        ok = bool(np.all(out == np.float16(args.expect)))
        print("check", "PASS" if ok else "FAIL", f"(expected all {args.expect})")
        if not ok:
            raise SystemExit(1)
    if args.bench:
        for _ in range(20):
            request.infer({0: x})
        times = []
        for _ in range(args.bench):
            t = time.perf_counter()
            request.infer({0: x})
            times.append((time.perf_counter() - t) * 1e3)
        times.sort()
        print(f"bench {args.bench}: p50 {statistics.median(times):.3f} ms  "
              f"p90 {times[int(0.9 * len(times))]:.3f} ms  min {times[0]:.3f} ms", flush=True)


if __name__ == "__main__":
    main()
