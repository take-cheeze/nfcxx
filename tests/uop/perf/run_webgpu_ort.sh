#!/usr/bin/env bash
# Times onnxruntime-web's WebGPU execution provider in headless Chrome (see webgpu_ort_bench.html). The page loads
# onnxruntime-web ORT_WEB_VERSION (pinned, released at least two weeks before the run) from jsdelivr. CHROME overrides
# the Chrome binary. Prints one JSON line per case on stdout.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ORT_WEB_VERSION=${ORT_WEB_VERSION:-1.30.0}
py=${TG_PY:-python3}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
b=$(mktemp -d); trap 'rm -rf "$b"' EXIT
"$py" tests/uop/perf/gen_ort_models.py "$b/ort_models.js"
sed "s|ORT_SCRIPT_URL|https://cdn.jsdelivr.net/npm/onnxruntime-web@$ORT_WEB_VERSION/dist/ort.webgpu.min.js|" \
  tests/uop/perf/webgpu_ort_bench.html > "$b/webgpu_ort_bench.html"
"$chrome" --headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU --use-angle=metal \
  --enable-logging=stderr --v=0 "file://$b/webgpu_ort_bench.html" 2> "$b/chrome.log" >/dev/null &
pid=$!
for _ in $(seq 1 900); do grep -q PERF_DONE "$b/chrome.log" 2>/dev/null && break; sleep 1; done
kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
grep -o 'PERF[_A-Z]* .*' "$b/chrome.log" | sed 's/"$//' | sed 's/\\"/"/g'
