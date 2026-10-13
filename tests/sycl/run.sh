#!/usr/bin/env bash
# SYCL tests (lib/sycl, docs/notes/sycl-webgpu.md).
#   host path     each program builds with g++ and with nfcxx (--cpu) and prints its "ok" line.
#   WebGPU path   scripts/sycl-build.sh compiles the device pass (WGSL) and the host side with nfcxx; the program runs the
#                 kernels through tests/sycl/server.cjs (Chromium's WebGPU: a GPU, or SwiftShader without one).
#                 Needs the Path B harness (scripts/setup-pathb.sh), the nfcxx build (setup-edg.sh, setup-qbe.sh), node,
#                 Playwright and a Chromium with WebGPU. The WebGPU part skips (exit 0) when one is missing.
# Programs:  pass: prints "NAME ok";  trap: the run fails with exit 71 and says why;  refuse: the device compile exits 3.
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
nfcxx=$root/nfcxx
have_nfcxx=0
[ -x "$root/build/edg/bin/eccp" ] && [ -x "$root/build/qbe/qbe" ] && have_nfcxx=1

# ---- host path
for t in vecadd saxpy2d reduce bytes chain matmul usm tables libm groups barvar atomics redcustom; do
  want="$t ok"
  if "$root/scripts/sycl-build.sh" --cpu "$t.cpp" -o "$out/$t.g++" > "$out/$t.log" 2>&1 && [ "$("$out/$t.g++" | tail -1)" = "$want" ]; then
    echo "host g++   $t: ok"
  else
    echo "host g++   $t: FAIL"; tail -3 "$out/$t.log"; fail=1
  fi
  # redcustom has a volatile store in a kernel: the qbe backend cannot compile it for the host path (cproc), the WebGPU path never does
  if [ $have_nfcxx = 1 ] && [ "$t" != redcustom ]; then
    if "$root/scripts/sycl-build.sh" --cpu --cxx="$nfcxx" "$t.cpp" -o "$out/$t.nfcxx" > "$out/$t.log" 2>&1 && [ "$("$out/$t.nfcxx" | tail -1)" = "$want" ]; then
      echo "host nfcxx $t: ok"
    else
      echo "host nfcxx $t: FAIL"; tail -3 "$out/$t.log"; fail=1
    fi
  fi
done

# ---- WebGPU path
if [ ! -x "$root/build/pathb/cmake/bin/cpfe" ] || [ $have_nfcxx = 0 ] || ! command -v node >/dev/null || ! node server.cjs --probe >/dev/null 2>&1; then
  echo "SKIP: sycl webgpu: needs the Path B harness, the nfcxx build, node, Playwright and a Chromium with WebGPU"
  exit $fail
fi
export NFCXX_SYCL_NODE=${NFCXX_SYCL_NODE:-node}
build() { "$root/scripts/sycl-build.sh" --cxx="$nfcxx" "$1.cpp" -o "$out/$1" > "$out/$1.log" 2>&1; }
for t in vecadd saxpy2d reduce bytes chain matmul usm tables libm groups barvar atomics redcustom; do
  if build $t && [ "$("$out/$t" 2>"$out/$t.err" | tail -1)" = "$t ok" ]; then
    echo "webgpu     $t: ok"
  else
    echo "webgpu     $t: FAIL"; tail -3 "$out/$t.log" "$out/$t.err" 2>/dev/null; fail=1
  fi
done
# a trap: the kernel divides by zero
if build trap_div; then
  "$out/trap_div" > "$out/trap_div.out" 2> "$out/trap_div.err"; rc=$?
  if [ $rc = 71 ] && grep -q "division by zero" "$out/trap_div.err"; then echo "webgpu     trap_div: trapped (exit 71)"; else echo "webgpu     trap_div: FAIL (exit $rc)"; cat "$out/trap_div.err"; fail=1; fi
else echo "webgpu     trap_div: FAIL (build)"; tail -3 "$out/trap_div.log"; fail=1; fi
# a refusal: double
rc=0; "$root/scripts/sycl-build.sh" --cxx="$nfcxx" refuse_double.cpp -o "$out/refuse_double" > "$out/refuse.log" 2>&1 || rc=$?
if [ $rc = 3 ] && grep -q "double" "$out/refuse.log"; then echo "webgpu     refuse_double: refused (exit 3)"; else echo "webgpu     refuse_double: FAIL (exit $rc)"; cat "$out/refuse.log"; fail=1; fi
exit $fail
