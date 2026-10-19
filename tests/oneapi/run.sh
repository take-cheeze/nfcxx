#!/usr/bin/env bash
# SYCL kernel integration on the real oneAPI headers (docs/notes/sycl-kernel-builtins.md): the pre-pass records each kernel
# (stable name, closure size, parameters) and the generated integration header holds its KernelInfoData. Skipped without the
# oneAPI headers (ONEAPI_INC, default /opt/intel/oneapi/compiler/latest/include).
cd "$(dirname "$0")/../.."
inc=${ONEAPI_INC:-/opt/intel/oneapi/compiler/latest/include}
[ -f "$inc/sycl/detail/kernel_desc.hpp" ] || { echo "skip tests/oneapi (no oneAPI headers at $inc)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
# Pre-pass: one record per kernel, with the closure size (1 for an empty lambda, 4 for one int) and its one parameter.
NFCXX_SYCL_PASS=1 NFCXX_SYCL_DUMP="$tmp/dump" ./nfcxx -c -I"$inc" tests/oneapi/prepass_kernels.cpp -o "$tmp/p.o" > /dev/null 2>&1
n=$(wc -l < "$tmp/dump")
if [ "$n" != 2 ]; then echo "FAIL pre-pass: $n records, want 2"; fail=1; fi
awk -F'\t' '$2 == 1 && $6 == 0 { a = 1 } $2 == 4 && $6 == 1 && $7 == 1 && $8 == 4 && $9 == 0 { b = 1 } END { exit !(a && b) }' "$tmp/dump" \
  || { echo "FAIL pre-pass: want a size-1 kernel with no captures and a size-4 kernel with one standard-layout int"; fail=1; }
# Generated header: one specialization per kernel, naming the file it came from.
scripts/sycl-integration-header.sh "$tmp/dump" > "$tmp/integ.hpp" || fail=1
[ "$(grep -c 'template <> struct KernelInfoData<' "$tmp/integ.hpp")" = 2 ] || { echo "FAIL header: want 2 specializations"; fail=1; }
grep -q 'getKernelSize() { return 4; }' "$tmp/integ.hpp" || { echo "FAIL header: the size-4 kernel"; fail=1; }
# The whole build: the queue file with the macro set by the second pass compiles to an object.
if ./nfcxx -c -I"$inc" tests/oneapi/prepass_kernels.cpp -o "$tmp/full.o" > "$tmp/full.log" 2>&1 && [ -f "$tmp/full.o" ]; then
  echo "ok   tests/oneapi/prepass_kernels.cpp (two-pass build)"
else
  echo "FAIL tests/oneapi/prepass_kernels.cpp (two-pass build)"; grep -v prelinker "$tmp/full.log" | head -8; fail=1
fi
[ $fail = 0 ] && echo "ok   tests/oneapi (pre-pass and integration header)"
exit $fail
