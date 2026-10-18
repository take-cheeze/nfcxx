#!/usr/bin/env bash
# build.sh: the open-source compiler and libc++abi runtime the macOS arm64 cross link needs (see README.md). Compiles the
# sources in src/ for arm64-apple-darwin with the cross configuration (build/cross-macos.env) and archives them into
# build/macos-rt/libnfcxx-darwin-rt.a, which scripts/cross-macos-link.sh adds to the link when it exists.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
envf="$root/build/cross-macos.env"
[ -f "$envf" ] || { echo "build.sh: $envf is missing; run scripts/setup-cross-macos.sh first" >&2; exit 2; }
. "$envf"
src="$root/tests/macos-sysroot/runtime/src"
out="$root/build/macos-rt"
mkdir -p "$out"
cd "$out"
tgt=(--target=arm64-apple-darwin)
inc=(-nostdinc -isystem "$NFCXX_MACOS_SYSROOT" -isystem "$(clang -print-resource-dir)/include")

# compiler-rt's atomic.c picks its lock by __APPLE__ (OSSpinLock, an SDK header). -U__APPLE__ takes the portable branch,
# which is plain C11 atomics; the sized __atomic_* functions the link needs are the same either way.
clang "${tgt[@]}" "${inc[@]}" -I "$src/compiler-rt/lib/builtins" -U__APPLE__ -O2 -c "$src/compiler-rt/lib/builtins/atomic.c" -o atomic.o

cxxinc=(-nostdinc++ -isystem "$root/tests/macos-sysroot/cxx" -isystem "$NFCXX_LIBCXX" -isystem "$NFCXX_MACOS_SYSROOT"
        -isystem "$(clang -print-resource-dir)/include" -I "$src/libcxxabi/include" -I "$src/libcxxabi/src" -I "$src/libcxx/src")
for f in stdlib_new_delete cxa_virtual cxa_vector abort_message stdlib_typeinfo; do
  clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$src/libcxxabi/src/$f.cpp" -o "$f.o"
done
# new_handler.cpp uses constinit, so it is built as C++20 (as libc++ builds it).
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++20 -fno-exceptions -fno-rtti -O2 -c "$src/libcxx/src/new_handler.cpp" -o new_handler.o
# private_typeinfo.cpp uses dynamic_cast itself, so it is built with RTTI on (no -fno-rtti).
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -O2 -c "$src/libcxxabi/src/private_typeinfo.cpp" -o private_typeinfo.o

rm -f libnfcxx-darwin-rt.a
llvm-ar rcs libnfcxx-darwin-rt.a atomic.o stdlib_new_delete.o cxa_virtual.o cxa_vector.o abort_message.o stdlib_typeinfo.o private_typeinfo.o new_handler.o
echo "built $out/libnfcxx-darwin-rt.a"
