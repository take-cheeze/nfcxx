#!/usr/bin/env bash
# Differential check of the C++ SPIR-V emitter (build/pathb-spirv-emit) against scripts/pathb-spirv-emit.rb, with no GPU:
# the device IR of every SYCL test program (as scripts/sycl-build.sh makes it), emitted in both modes (Vulkan and
# --kernel-cl), must give the same module, manifest, exit status and message from both. Extra IR files may be named.
#   tools/pathb-spirv-emit/check.sh [-j N] [FILE.ir ...]
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
jobs=$(nproc 2>/dev/null || echo 4)
if [ "${1:-}" = -j ]; then jobs=$2; shift 2; fi
ninja -C "$root/tools/pathb-spirv-emit" > /dev/null || { echo "check: building the C++ emitter failed"; exit 1; }
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export root out
irs=("$@")
if [ ${#irs[@]} = 0 ]; then
  # the device pass of each test (sycl-build.sh: pathb-dump --ir with __NFCXX_SYCL_DEVICE__ and the runtime's headers)
  dump() {
    local t=$1 b
    b=$(basename "$t" .cpp)
    (cd "$root/tests/sycl" && "$root/scripts/pathb-dump" --ir -std=c++17 -D__NFCXX_SYCL_DEVICE__ -I"$root/lib/sycl/include" \
      "$t" > "$out/$b.ir" 2> "$out/$b.dump.err") || rm -f "$out/$b.ir"
  }
  export -f dump
  ls "$root"/tests/sycl/*.cpp | xargs -P "$jobs" -I{} bash -c 'dump "$1"' _ {}
  irs=("$out"/*.ir)
fi
one() {
  local ir=$1 b mode tag rc
  b=$(basename "$ir" .ir)
  for mode in "" --kernel-cl; do
    tag=${mode:+-cl}
    NFCXX_SPIRV_EMITTER=check "$root/scripts/spirv-emit" $mode --manifest="$out/$b$tag.man" "$ir" > /dev/null 2> "$out/$b$tag.err"
    rc=$?
    if [ $rc = 99 ]; then echo "$b${tag}: DIFFERS $(head -1 "$out/$b$tag.err" | sed 's/.*: //')"; else echo "$b${tag}: same (exit $rc)"; fi
  done
}
export -f one
printf '%s\n' "${irs[@]}" | xargs -P "$jobs" -I{} bash -c 'one "$1"' _ {} | sort > "$out/report"
n=$(grep -c . "$out/report")
bad=$(grep -c DIFFERS "$out/report")
grep DIFFERS "$out/report"
echo "check: $((n - bad)) of $n emits the same from both emitters"
[ "$bad" = 0 ]
