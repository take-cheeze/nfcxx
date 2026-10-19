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
git -C "$llvm" sparse-checkout set --cone compiler-rt/lib/builtins libcxxabi libcxx/include libcxx/src libunwind/include
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
# The sized add/sub/and/or/xor _fetch functions (for example __atomic_add_fetch_8) are not in compiler-rt; they are in
# this repository (src/atomic_fetch.c), written with clang's inline __atomic builtins.
clang "${tgt[@]}" "${inc[@]}" -O2 -c "$root/tests/macos-sysroot/runtime/src/atomic_fetch.c" -o atomic_fetch.o

cxxinc=(-nostdinc -nostdinc++ -isystem "$root/tests/macos-sysroot/cxx" -isystem "$NFCXX_LIBCXX" -isystem "$NFCXX_MACOS_SYSROOT"
        -isystem "$(clang -print-resource-dir)/include" -I "$src/libcxxabi/include" -I "$src/libcxxabi/src" -I "$src/libcxx/src")
for f in stdlib_new_delete cxa_virtual cxa_vector abort_message; do
  clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$src/libcxxabi/src/$f.cpp" -o "$f.o"
done
# cxa_demangle.cpp is libc++abi's demangler (__cxa_demangle, the ___cxa_demangle name). Its ItaniumDemangle.h lives under
# libcxxabi/src/demangle, which the -I above reaches. Built with only the clean-room sysroot and the libc++ headers.
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$src/libcxxabi/src/cxa_demangle.cpp" -o cxa_demangle.o
# stdlib_typeinfo.cpp is the key function of std::type_info, so it emits the _ZTISt9type_info object only with RTTI on.
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -frtti -O2 -c "$src/libcxxabi/src/stdlib_typeinfo.cpp" -o stdlib_typeinfo.o
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$root/tests/macos-sysroot/runtime/src/streambuf_seekpos.cpp" -o streambuf_seekpos.o
# new_handler.cpp (libc++'s copy of std::get_new_handler and set_new_handler) is not built: libc++abi's
# cxa_default_handlers.cpp defines set_new_handler against the runtime's __cxa_new_handler, and two definitions would collide.
# private_typeinfo.cpp uses dynamic_cast itself, so it is built with RTTI on (no -fno-rtti).
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -O2 -c "$src/libcxxabi/src/private_typeinfo.cpp" -o private_typeinfo.o
# cxa_exception.cpp defines __cxa_uncaught_exception (the ___cxa_uncaught_exception name the cross link needs). It is
# built with exceptions and RTTI on, as libc++abi builds it; the _LIBCPP opt-in keeps std::unexpected_handler, which
# its headers use. The _Unwind_* functions it calls are the system unwinder's, from libunwind's headers at the pin.
# The rest of the exception runtime that cxa_exception.o needs: the terminate and unexpected handlers (std::terminate,
# get_terminate), the per-thread globals (__cxa_get_globals), the personality routine (__gxx_personality_v0), the
# fallback allocator for exception objects, and the default handlers. Built as libc++abi builds them: exceptions on.
eh=(-I "$src/libunwind/include" -D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS -std=c++17 -fexceptions -O2)
for f in cxa_exception cxa_exception_storage cxa_personality fallback_malloc stdlib_exception; do
  clang++ "${tgt[@]}" "${cxxinc[@]}" "${eh[@]}" -c "$src/libcxxabi/src/$f.cpp" -o "$f.o"
done
# cxa_handlers.cpp also defines std::unexpected, std::get_terminate and std::terminate, which libC.a (EDG's runtime)
# defines too; two definitions collide at link time. The copy built here drops those three public functions and keeps
# the handler storage and __terminate/__unexpected, which cxa_exception needs. Each block must match exactly once.
python3 - "$src/libcxxabi/src/cxa_handlers.cpp" cxa_handlers.cpp <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
blocks = [
    r'__attribute__\(\(noreturn\)\)\nvoid\nunexpected\(\)\n\{\n.*?\n\}\n',
    r'terminate_handler\nget_terminate\(\) noexcept\n\{\n.*?\n\}\n',
    r'__attribute__\(\(noreturn\)\)\nvoid\nterminate\(\) noexcept\n\{\n.*?\n\}\n',
]
for b in blocks:
    hits = re.findall(b, text, flags=re.S)
    assert len(hits) == 1, ('cxa_handlers block not found exactly once', b)
    text = re.sub(b, '', text, count=1, flags=re.S)
open(dst, 'w').write(text)
PY
clang++ "${tgt[@]}" "${cxxinc[@]}" "${eh[@]}" -c cxa_handlers.cpp -o cxa_handlers.o
# cxa_default_handlers.cpp uses constinit, so it is built as C++20 (as new_handler.cpp is).
clang++ "${tgt[@]}" "${cxxinc[@]}" -I "$src/libunwind/include" -D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS \
  -std=c++20 -fexceptions -O2 -c "$src/libcxxabi/src/cxa_default_handlers.cpp" -o cxa_default_handlers.o

rm -f libnfcxx-darwin-rt.a
# Only members with no symbol in libC.a go into the archive. libC.a (EDG's runtime) owns the EH, type_info,
# handler and new/delete names that the other members define; the real libc++ on the Mac exports the libc++ names at run time.
llvm-ar rcs libnfcxx-darwin-rt.a streambuf_seekpos.o atomic.o atomic_fetch.o abort_message.o cxa_exception.o cxa_handlers.o cxa_exception_storage.o cxa_personality.o fallback_malloc.o
echo "built $out/libnfcxx-darwin-rt.a from llvm-project $pin"

# libc++ itself, built from LLVM's own sources at the pin with the cross clang (not a hand-written subset), into a
# separate archive. _LIBCPP_NO_ABI_TAG keeps the names untagged, which matches the Mac's libc++ spellings. The config
# site is ours (tests/macos-sysroot/cxx/__config_site); the headers and sources are LLVM's at the pin.
cxxlib=(-nostdinc++ -isystem "$root/tests/macos-sysroot/cxx" -isystem "$src/libcxx/include" -isystem "$NFCXX_MACOS_SYSROOT"
        -isystem "$(clang -print-resource-dir)/include" -I "$src/libcxxabi/include" -I "$src/libcxx/src")
cxxlibdefs=(-D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_NO_ABI_TAG -D_LIBCXXABI_BUILDING_LIBRARY)
mkdir -p libcxx-obj
rm -f libc++-darwin.a libcxx-obj/*.o
cxxlib_fail=0
for f in "$src"/libcxx/src/*.cpp "$src"/libcxx/src/filesystem/*.cpp; do
  [ -f "$f" ] || continue
  o="libcxx-obj/$(basename "$(dirname "$f")")_$(basename "$f" .cpp).o"
  if ! clang++ "${tgt[@]}" "${cxxlib[@]}" "${cxxlibdefs[@]}" -std=c++20 -fexceptions -O2 -c "$f" -o "$o" 2>"libcxx-obj/$(basename "$f" .cpp).err"; then
    echo "build.sh: libc++ source did not compile: $f" >&2; cxxlib_fail=$((cxxlib_fail+1))
  fi
done
[ "$cxxlib_fail" = 0 ] || echo "build.sh: $cxxlib_fail libc++ sources failed; see build/macos-rt/libcxx-obj/*.err" >&2
ls libcxx-obj/*.o >/dev/null 2>&1 && llvm-ar rcs libc++-darwin.a libcxx-obj/*.o && echo "built $out/libc++-darwin.a ($(ls libcxx-obj/*.o | wc -l) objects)"
# The LLVM sources are removed only now, after the libc++ step that reads them.
rm -rf "$llvm"
