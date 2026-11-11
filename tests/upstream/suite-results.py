#!/usr/bin/env python3
"""Summarize native harness formats (lit JSON, DejaGnu and EDG tar/JSON).

Python is already a native LLVM/EDG harness requirement. No test is executed
or expectation rerecorded by this reporting tool.
"""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path
import re
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("--gcc", required=True, type=Path)
parser.add_argument("--clang", required=True, type=Path)
parser.add_argument("--clang-retry", type=Path)
parser.add_argument("--edg", required=True, type=Path)
parser.add_argument("--positive", required=True, type=Path)
parser.add_argument("--json", type=Path)
args = parser.parse_args()
results = {}

gcc = Counter()
files = set()
sums = sorted(args.gcc.glob("worker-*/g++.sum"))
if not sums or not (args.gcc / "combined.sum").exists():
    raise SystemExit("GCC run is incomplete: combined.sum missing")
for path in sums:
    for line in path.read_text(errors="replace").splitlines():
        match = re.match(r"^(PASS|FAIL|XFAIL|XPASS|UNSUPPORTED|UNRESOLVED|UNTESTED|ERROR): (.*)", line)
        if not match:
            continue
        gcc[match[1]] += 1
        source = re.match(r"(\S+\.(?:C|cpp|c|S|f))\b", match[2])
        if source:
            files.add(source[1])
results["gcc"] = {"assertions": dict(gcc), "source_labels": len(files), "workers": len(sums)}

clang_json = json.loads((args.clang / "results.json").read_text())
clang_tests = clang_json["tests"]
first_clang = Counter(test["code"] for test in clang_tests)
merged_clang = {test["name"]: test for test in clang_tests}
retry_counts = Counter()
if args.clang_retry:
    retry = json.loads((args.clang_retry / "results.json").read_text())
    for test in retry["tests"]:
        if test["name"] not in merged_clang or merged_clang[test["name"]]["code"] not in ("FAIL", "UNRESOLVED", "TIMEOUT"):
            raise SystemExit("Unexpected test in Clang verification rerun")
        merged_clang[test["name"]] = test
        retry_counts[test["code"]] += 1
clang = Counter(test["code"] for test in merged_clang.values())
results["clang"] = {"tests": len(clang_tests), "statuses": dict(clang), "first_run": dict(first_clang),
                    "verification_rerun": dict(retry_counts), "elapsed": clang_json.get("elapsed")}

edg_dir = args.edg / "edg_x86_64"
executed = (edg_dir / "executed.elist").read_text().splitlines()
edg = Counter()
output_diffs = 0
archives = list(edg_dir.rglob("*.rt.tar.gz"))
for archive in archives:
    with tarfile.open(archive) as source:
        metadata = json.load(source.extractfile("metadata.json"))
    output_diffs += bool(metadata.get("combined_diff_hash"))
    for case in metadata["cases"]:
        edg[case["status"]["result"].split("--OUTPUT MISMATCH")[0]] += 1
changes = edg_dir / "changes.elog"
changed_lines = changes.read_text(errors="replace").splitlines() if changes.exists() else []
regressed_file = edg_dir / "regressions.elist"
regressed_entries = regressed_file.read_text().splitlines() if regressed_file.exists() else []
results["edg"] = {
    "executed_entries": len(executed), "metadata_archives": len(archives),
    "variants": dict(edg), "entries_with_output_diffs": output_diffs,
    "change_lines": len(changed_lines),
    "regressed_entries": len(regressed_entries),
}

with (args.positive / "results.tsv").open() as source:
    positive_rows = list(csv.DictReader(source, delimiter="\t"))
with (args.positive / "manifest.tsv").open() as source:
    expected = list(csv.DictReader(source, delimiter="\t"))
if len(positive_rows) != len(expected) * 4 or len({(row["id"], row["route"]) for row in positive_rows}) != len(positive_rows):
    raise SystemExit("GCC positive survey incomplete or duplicate cells")
positive = {route: dict(Counter(row["status"] for row in positive_rows if row["route"] == route))
            for route in ("host", "qbe", "gcc", "pathb")}
results["gcc_positive"] = {"sources": len(expected), "routes": positive}
if args.json:
    args.json.write_text(json.dumps(results, indent=2) + "\n")

print("# GCC, Clang and EDG: broad local suite runs\n")
print("Native results use the suites' own harnesses and assertions. They are compiler/package baselines, not nfcxx backend results.")
print("GCC uses installed GCC 15.2.0 and the 15.2.0 tests, eight native DejaGnu workers. Clang uses installed 21.1.8 with pinned 21.1.0 regression tests and lit; uninstalled GoogleTest Unit binaries are excluded.")
print("EDG runs the pinned fork's full tree in its C-generating x86-64 Docker configuration; other configurations, including the currently unbuildable C++ generator, are not claimed.\n")
print("| Run | Outcomes |")
print("| --- | --- |")
print("| GCC / DejaGnu assertions | " + "; ".join(f"{name}: {count}" for name, count in sorted(gcc.items())) + " |")
print("| Clang / lit tests | " + "; ".join(f"{name}: {count}" for name, count in sorted(clang.items())) + " |")
print("| EDG / actual variant statuses | " + "; ".join(f"{name}: {count}" for name, count in sorted(edg.items())) + " |")
print(f"\nGCC produced {len(files):,} distinct source labels across {len(sums)} workers; these include common C/C++ tests. Assertions and test-source counts are different units.")
print(f"Clang reported {len(clang_tests):,} regression tests. Unsupported tests remain distinct from passes; missing test binaries and snapshot/package differences must be triaged before identifying compiler regressions.")
if retry_counts:
    print("The first Clang run recorded " + ", ".join(f"{name}={count}" for name, count in sorted(first_clang.items())) + ".")
    print("One verification rerun of its failures, after completing source-side prerequisites, recorded " + ", ".join(f"{name}={count}" for name, count in sorted(retry_counts.items())) + "; the table merges those verified outcomes. Original and rerun JSON/logs are both retained.")
print(f"EDG's executed list has {len(executed):,} entries, with {len(archives):,} metadata archives; {output_diffs:,} entries differ in recorded output, {len(regressed_entries):,} entries are listed as regressions and changes.elog has {len(changed_lines):,} lines. Actual failure counts include previously expected failures; changed expectations are not rerecorded.\n")
print("## GCC positive sources through nfcxx\n")
print(f"All {len(expected):,} sources in the conservative positive manifest were compile-surveyed. Host checks syntax; nfcxx produces objects. No unreviewed program is executed and no general DejaGnu translation is claimed.\n")
print("| Route | Accepted | Rejected | Crashed | Timed out | Mode unavailable |")
print("| --- | --- | --- | --- | --- | --- |")
for route, counts in positive.items():
    print("| " + route + " | " + " | ".join(str(counts.get(name, 0)) for name in ("accepted", "rejected", "crash", "timeout", "mode-unavailable")) + " |")
print("\nRaw paths for this measurement:\n")
for name, path in (("GCC", args.gcc), ("Clang", args.clang), ("EDG", args.edg), ("nfcxx GCC positives", args.positive)):
    print(f"- {name}: `{path}`")
if args.clang_retry:
    print(f"- Clang verification rerun: `{args.clang_retry}`")
print("\nThe EDG launcher initially overrode the JSON timeout with zero; its last large C99 case completed naturally in 5m52s. No case was terminated. The wrapper now passes the timeout explicitly.")
print("An edit to the running EDG shell wrapper caused its final shell check to fail after the native harness had completed. The saved native executed list, per-case archives and comparison logs were validated directly for this report; the corrected wrapper subsequently passed a fresh native regressions run (19 entry points) with the explicit timeout.")
print("Three GCC positive-survey sources also fail the host check: two require generated PCH headers and one belongs to an AArch64-specific driver. These observations are not nfcxx defects. Remaining source selections still need native-target/driver review before becoming assertions.")
print("\nSee [local commands and scope](../../tests/upstream/README.md) and the [CI plan](cpp-test-ci-plan.md). Native failures and compile-survey observations are retained for investigation; no claim of full conformance follows from these runs.")
