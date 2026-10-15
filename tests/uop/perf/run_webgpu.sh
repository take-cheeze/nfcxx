#!/usr/bin/env bash
# Times tinygrad's WGSL kernels on WebGPU in headless Chrome (see webgpu_bench.html). Needs tinygrad in a venv:
# TG_PY=/path/to/venv/bin/python; CHROME overrides the Chrome binary. Prints one JSON line per case on stdout.
set -euo pipefail
cd "$(dirname "$0")/../../.."
py=${TG_PY:-python3}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT
"$py" tests/uop/perf/gen_webgpu.py "$b/bench_cases.js" 2>/dev/null
cp tests/uop/perf/webgpu_bench.html "$b/"
"$chrome" --headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU --use-angle=metal \
  --enable-logging=stderr --v=0 "file://$b/webgpu_bench.html" 2> "$b/chrome.log" >/dev/null &
pid=$!
for _ in $(seq 1 900); do grep -q PERF_DONE "$b/chrome.log" 2>/dev/null && break; sleep 1; done
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
grep -o 'PERF[_A-Z]* .*' "$b/chrome.log" | sed 's/"$//' | sed 's/\\"/"/g'
