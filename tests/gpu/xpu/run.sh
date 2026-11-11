#!/usr/bin/env bash
# SYCL vecadd (vecadd.cpp) built by icpx -fsycl and run on the Intel XPU (Level Zero GPU) over 50000 elements. A mutant
# (add -> sub) must fail the same run. Needs the oneAPI compiler (ONEAPI_SETVARS, default /opt/intel/oneapi/setvars.sh)
# and a SYCL GPU device; skips (exit 0) when either is missing.
set -euo pipefail
cd "$(dirname "$0")"
setvars=${ONEAPI_SETVARS:-/opt/intel/oneapi/setvars.sh}
if [ -f "$setvars" ]; then set +eu; source "$setvars" --force >/dev/null 2>&1; set -eu; fi
devices=$(sycl-ls 2>/dev/null || true)
if ! command -v icpx >/dev/null || ! grep -q 'gpu\]' <<< "$devices"; then
  echo "SKIP: gpu xpu: needs icpx and a SYCL GPU device (sycl-ls)"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 1. The kernel builds and runs on the XPU; every element is checked by the program.
icpx -fsycl -O2 vecadd.cpp -o "$out/vecadd"
if "$out/vecadd"; then echo "run vecadd: ok"; else echo "run vecadd: FAIL"; fail=1; fi

# 2. A mutant (add -> sub) must fail the same run.
sed 's/ra\[i\] + rb\[i\]/ra[i] - rb[i]/' vecadd.cpp > "$out/mut.cpp"
icpx -fsycl -O2 "$out/mut.cpp" -o "$out/mut"
if "$out/mut" >/dev/null 2>&1; then echo "mutant vecadd: FAIL (not caught)"; fail=1; else echo "mutant vecadd: caught"; fi

exit $fail
