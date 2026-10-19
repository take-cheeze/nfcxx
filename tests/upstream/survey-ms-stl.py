#!/usr/bin/env python3
"""Compile-only portability inventory, NOT Microsoft's native STL matrix."""
import concurrent.futures
import csv
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[2]
snapshot = root / "build/testsuite-snapshots"
src = snapshot / "microsoft-stl"
out = Path(os.environ.get("MS_STL_SURVEY_OUT", snapshot / "microsoft-stl-host-survey")).resolve()
out.mkdir(parents=True, exist_ok=True)
started = out / "started"
with started.open("x") as stream:
    stream.write(str(time.time()) + "\n")
compiler = os.environ.get("HOST_CXX", "/usr/bin/g++")
jobs = int(os.environ.get("SURVEY_JOBS", "8"))
limit = int(os.environ.get("SURVEY_TIMEOUT", "60"))
files = sorted(p for suite in ("std", "tr1") for p in (src / "tests" / suite).rglob("*")
               if p.is_file() and p.name in ("test.cpp", "test.compile.pass.cpp"))
if not files:
    raise SystemExit("Microsoft STL snapshot missing")
subprocess.run([compiler, "--version"], stdout=(out / "compiler.txt").open("w"), check=True)
(out / "scope.json").write_text(json.dumps({
    "standard": "c++23", "sources": len(files), "workers": jobs, "timeout_seconds": limit,
    "scope": "Local libstdc++ syntax-only observations; no env.lst expansion, no execution, no native MSVC/STL claim",
    "snapshot": subprocess.check_output(["git", "-C", str(src), "rev-parse", "HEAD"], text=True).strip(),
}, indent=2) + "\n")


def check(item):
    index, source = item
    command = [compiler, "-std=c++23", "-pthread", "-fsyntax-only", "-I", str(src / "tests/std/include"), str(source)]
    with (out / f"{index:04d}.log").open("w") as log:
        try:
            rc = subprocess.run(command, cwd=source.parent, stdout=log, stderr=subprocess.STDOUT, timeout=limit).returncode
            status = "accepted" if rc == 0 else ("crash" if rc < 0 else "rejected")
        except subprocess.TimeoutExpired:
            status, rc = "timeout", 124
    return [str(source.relative_to(src)), "c++23", status, rc, f"{index:04d}.log"]


with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
    rows = list(pool.map(check, enumerate(files)))
with (out / "results.tsv").open("w") as stream:
    writer = csv.writer(stream, delimiter="\t")
    writer.writerow(["source", "standard", "status", "exit", "log"])
    writer.writerows(rows)
(out / "completed").write_text(str(time.time()) + "\n")
print(f"Microsoft STL source portability observations: {out / 'results.tsv'}")
