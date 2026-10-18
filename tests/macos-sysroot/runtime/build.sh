#!/usr/bin/env bash
# build.sh: the open-source compiler and libc++abi runtime the macOS arm64 cross link needs (see README.md). Fetches the
# LLVM sources at the commit pinned in LLVM_PIN (a sparse, shallow clone of github.com/llvm/llvm-project, nothing is
# vendored), compiles them for arm64-apple-darwin with the cross configuration (build/cross-macos.env) and archives them
# into build/macos-rt/libnfcxx-darwin-rt.a, which scripts/cross-macos-link.sh adds to the link when it exists.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
envf="$root/build/cross-macos.env"
[ -f "$envf" ] || { echo "build.sh: $envf is missing; run scripts/setup-cross-macos.sh first" >&2; exit 2; }
. "$envf"
pin=$(sed -n 's/^commit=//p' "$root/tests/macos-sysroot/runtime/LLVM_PIN")
[ -n "$pin" ] || { echo "build.sh: no commit in tests/macos-sysroot/runtime/LLVM_PIN" >&2; exit 2; }

# The sources: exactly the pinned commit, sparse (only the three trees the archive needs), shallow and without blobs
# until checkout. The checked-out HEAD must equal the pin, or the build stops.
llvm="$root/build/llvm-src"
rm -rf "$llvm"; mkdir -p "$llvm"
git -C "$llvm" init -q
git -C "$llvm" remote add origin https://github.com/llvm/llvm-project
git -C "$llvm" sparse-checkout set --cone compiler-rt/lib/builtins libcxxabi libcxx/src/include
git -C "$llvm" fetch -q --depth 1 --filter=blob:none origin "$pin"
git -C "$llvm" checkout -q FETCH_HEAD
[ "$(git -C "$llvm" rev-parse HEAD)" = "$pin" ] || { echo "build.sh: checked-out HEAD is not the pinned commit $pin" >&2; exit 1; }

src="$llvm"
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
for f in stdlib_new_delete cxa_virtual cxa_vector abort_message; do
  clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$src/libcxxabi/src/$f.cpp" -o "$f.o"
done

rm -f libnfcxx-darwin-rt.a
llvm-ar rcs libnfcxx-darwin-rt.a atomic.o stdlib_new_delete.o cxa_virtual.o cxa_vector.o abort_message.o
rm -rf "$llvm"
echo "built $out/libnfcxx-darwin-rt.a from llvm-project $pin"
