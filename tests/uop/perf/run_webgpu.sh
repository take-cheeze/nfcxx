#!/usr/bin/env bash
# Times the WGSL cases that bench_np wrote (tests/uop/perf/bench_np.cpp --case-dir=DIR) on WebGPU in headless Chrome, with
# run_webgpu.html. Usage: tests/uop/perf/run_webgpu.sh DIR  -> one JSON line per case on stdout. Needs a Chrome with WebGPU
# (on macOS, Chrome over Metal; set CHROME to another path). Without one the run is skipped.
set -euo pipefail
cd "$(dirname "$0")/../../.."
dir=${1:?usage: run_webgpu.sh DIR}
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
if [ ! -x "$chrome" ]; then
  echo "SKIP uop/perf WebGPU: no Chrome at \"$chrome\" (set CHROME)"
  exit 0
fi
flags=(--headless=new --no-sandbox --enable-unsafe-webgpu --enable-features=WebGPU --virtual-time-budget=60000)
[ "$(uname -s)" = Darwin ] && flags+=(--use-angle=metal)

b=$(mktemp -d); trap 'rm -rf "$b"' EXIT
fail=0
for case_js in "$dir"/*.js; do
  name=$(basename "$case_js" .js)
  cp "$case_js" "$b/case.js"
  cp tests/uop/perf/run_webgpu.html "$b/run.html"
  # The DOM is read after the run's async work; a pending page is retried, not reported as a failure.
  for try in 1 2 3; do
    res=$("$chrome" "${flags[@]}" --dump-dom "file://$b/run.html" 2>/dev/null | sed -n 's/.*<pre id="result">\([^<]*\)<\/pre>.*/\1/p')
    [ "$res" != pending ] && break
  done
  case "$res" in
    PASS*) echo "{\"case\": \"$name\", \"status\": \"PASS\", \"result\": ${res#PASS }}" ;;
    FAIL*) echo "{\"case\": \"$name\", \"status\": \"FAIL\", \"message\": \"${res#FAIL }\"}"; fail=1 ;;
    *)     echo "{\"case\": \"$name\", \"status\": \"NO_RESULT\"}"; fail=1 ;;
  esac
done
exit $fail
