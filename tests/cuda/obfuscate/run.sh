#!/usr/bin/env bash
# Kernel name obfuscation (scripts/cuda-rewrite.rb --obfuscate=SEED; the driver's --obfuscate-kernels and
# NFCXX_OBFUSCATE_KERNELS, docs/notes/gpu.md "Kernel name obfuscation"). The rewrite checks need no CUDA toolkit: the
# host copy and the device unit must not carry a kernel's name, the names follow the seed, and the launches use them.
# The device checks (IR, PTX, the embedded kernel table) run when the Path B front end is built
# (scripts/setup-pathb.sh) and skip otherwise. ptxas and the GPU are not needed: the table is checked with a stand-in cubin.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
rw() { "$root/scripts/mrb" "$root/scripts/cuda-rewrite.rb" "$@"; }
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
names='ob_scale_kernel|ob_offset_kernel'
absent() { ! grep -Eq "$1" "${@:2}"; }     # none of the files has a match
present() { grep -Eq "$1" "$2"; }           # the file has a match
check() {  # check NAME COMMAND...: prints the result; a failing check does not stop the others
  local name=$1; shift
  if "$@"; then echo "obfuscate $name: ok"; else echo "obfuscate $name: FAIL"; fail=1; fi
}

rw --obfuscate=seedA kern.cu > "$out/host_a.cpp"
rw --obfuscate=seedA --device --kernels="$out/a.kernels" kern.cu > "$out/dev_a.cpp"
rw --obfuscate=seedA kern.cu > "$out/host_a2.cpp"
rw --obfuscate=seedA --device --kernels="$out/a2.kernels" kern.cu > "$out/dev_a2.cpp"
rw --obfuscate=seedB --device --kernels="$out/b.kernels" kern.cu > "$out/dev_b.cpp"
rw --device --kernels="$out/plain.kernels" kern.cu > "$out/dev_plain.cpp"

# 1. No kernel name in the host copy or the device unit.
check "names gone from host copy and device unit" absent "$names" "$out/host_a.cpp" "$out/dev_a.cpp"
# 2. The launches call the renamed kernels, and the kernel list has the two new names only.
check "launches use the new names" present '__nfcxx_cuda_launch\(__nfcxx_kn_' "$out/host_a.cpp"
check "launch of the template uses its wrapper" present '__nfcxx_cuda_launch\(__nfcxx_k__nfcxx_kn_' "$out/host_a.cpp"
check "kernel list is the two new names" bash -c \
  '[ "$(wc -l < "$1")" = 2 ] && [ "$(grep -c "^__nfcxx_kn_[0-9a-f]\{16\}$" "$1")" = 1 ] && [ "$(grep -c "^__nfcxx_k__nfcxx_kn_[0-9a-f]\{16\}_float$" "$1")" = 1 ]' _ "$out/a.kernels"
# 3. Deterministic for a seed; a different seed gives different names.
check "same seed, same output" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ \
  "$out/host_a.cpp" "$out/host_a2.cpp" "$out/dev_a.cpp" "$out/dev_a2.cpp"
check "other seed, other names" bash -c '! cmp -s "$1" "$2"' _ "$out/a.kernels" "$out/b.kernels"
# 3b. The C++ rewriter (the default, tools/cuda-rewrite) gives the same output as the Ruby reference, host and device.
[ -x "$root/build/cuda-rewrite" ] || make -s -C "$root/tools/cuda-rewrite"
"$root/build/cuda-rewrite" --obfuscate=seedA kern.cu > "$out/cxx_host_a.cpp"
"$root/build/cuda-rewrite" --obfuscate=seedA --device --kernels="$out/cxx_a.kernels" kern.cu > "$out/cxx_dev_a.cpp"
check "C++ rewriter matches the Ruby reference" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4" && cmp -s "$5" "$6"' _ \
  "$out/host_a.cpp" "$out/cxx_host_a.cpp" "$out/dev_a.cpp" "$out/cxx_dev_a.cpp" "$out/a.kernels" "$out/cxx_a.kernels"
# 4. Without the option the copies keep the names.
check "off by default" bash -c 'grep -q ob_scale_kernel "$1" && ! grep -q __nfcxx_kn_ "$2"' _ "$out/plain.kernels" "$out/dev_plain.cpp"

# 5. Device side: the IR, the PTX entries and the embedded kernel table carry the new names only. The entry of a C++
# kernel is its mangled name (_Z<len><name>...), as cuda-embed.rb matches it.
if [ -x "$root/build/pathb/cmake/bin/cpfe" ]; then
  "$root/scripts/pathb-dump" --ir --freestanding "$out/dev_a.cpp" > "$out/a.ir"
  kopts=(); while IFS= read -r k; do [ -n "$k" ] && kopts+=(--kernel="$k"); done < "$out/a.kernels"
  "$root/scripts/mrb" "$root/scripts/pathb-ptx-emit.rb" --sm=75 "${kopts[@]}" "$out/a.ir" > "$out/a.ptx"
  check "IR and PTX free of the names" absent "$names" "$out/a.ir" "$out/a.ptx"
  check "PTX entries are the new names" present '\.visible \.entry (_Z[0-9]+)?__nfcxx_kn_' "$out/a.ptx"
  # The table: a stand-in cubin (the table is the same whatever the image holds).
  head -c 256 /dev/urandom > "$out/stand_in.cubin"
  "$root/scripts/mrb" "$root/scripts/cuda-embed.rb" "$out/stand_in.cubin" "$out/a.ir" "$out/a.kernels" > "$out/tail.cpp"
  check "kernel table free of the names" absent "$names" "$out/tail.cpp"
  check "kernel table has the new entries" present '"_Z[0-9]+__nfcxx_kn_' "$out/tail.cpp"
else
  echo "obfuscate device checks: SKIP (Path B front end not built: scripts/setup-pathb.sh)"
fi

if [ "$fail" = 0 ]; then echo "obfuscate: all ok"; else echo "obfuscate: FAILED"; exit 1; fi
