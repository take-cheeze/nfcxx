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
git -C "$llvm" sparse-checkout set --cone compiler-rt/lib/builtins libcxxabi libcxx/include libcxx/src libcxx/vendor libunwind/include
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
clang++ "${tgt[@]}" "${cxxinc[@]}" -std=c++17 -fno-exceptions -fno-rtti -O2 -c "$root/tests/macos-sysroot/runtime/src/streambuf_seekpos.cpp" -o streambuf_seekpos.o
# new_handler.cpp (libc++'s copy of std::get_new_handler and set_new_handler) is not built: libc++abi's
# cxa_default_handlers.cpp defines set_new_handler against the runtime's __cxa_new_handler, and two definitions would collide.
# cxa_exception.cpp defines __cxa_uncaught_exception (the ___cxa_uncaught_exception name the cross link needs). It is
# built with exceptions and RTTI on, as libc++abi builds it; the _LIBCPP opt-in keeps std::unexpected_handler, which
# its headers use. The _Unwind_* functions it calls are the system unwinder's, from libunwind's headers at the pin.
# The rest of the exception runtime that cxa_exception.o needs: the terminate and unexpected handlers (std::terminate,
# get_terminate), the per-thread globals (__cxa_get_globals), the personality routine (__gxx_personality_v0), the
# fallback allocator for exception objects, and the default handlers. Built as libc++abi builds them: exceptions on.
eh=(-I "$src/libunwind/include" -D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS -std=c++17 -fexceptions -O2)
for f in cxa_exception cxa_exception_storage cxa_personality fallback_malloc; do
  clang++ "${tgt[@]}" "${cxxinc[@]}" "${eh[@]}" -c "$src/libcxxabi/src/$f.cpp" -o "$f.o"
done
# cxa_handlers.cpp is built whole: it defines std::unexpected, std::get_terminate and std::terminate. These are libc++abi's
# now; the EDG copies are left out of libC-darwin.a (see libc_drop below), so there is one definition of each.
clang++ "${tgt[@]}" "${cxxinc[@]}" "${eh[@]}" -c "$src/libcxxabi/src/cxa_handlers.cpp" -o cxa_handlers.o
# cxa_default_handlers.cpp uses constinit, so it is built as C++20 (as new_handler.cpp is).
# cxa_default_handlers.cpp defines the handler storage (__cxa_terminate_handler, which cxa_handlers.o reads), set_terminate and
# set_unexpected. It also defines std::set_new_handler, which libC.a's new-handler member owns, so the copy built here drops
# that one function (the block must match exactly once). __cxa_new_handler, the handler storage, stays.
python3 - "$src/libcxxabi/src/cxa_default_handlers.cpp" cxa_default_handlers.cpp <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
b = r'new_handler\nset_new_handler\(new_handler handler\) noexcept\n\{\n.*?\n\}\n'
assert len(re.findall(b, text, flags=re.S)) == 1, 'set_new_handler block not found exactly once'
open(dst, 'w').write(re.sub(b, '', text, count=1, flags=re.S))
PY
clang++ "${tgt[@]}" "${cxxinc[@]}" -I "$src/libunwind/include" -D_LIBCPP_ENABLE_CXX17_REMOVED_UNEXPECTED_FUNCTIONS \
  -std=c++20 -fexceptions -O2 -c cxa_default_handlers.cpp -o cxa_default_handlers.o
# The names EDG's runtime (libC.a) calls for terminate and unexpected, forwarded to the handlers above (see eh_glue.cpp).
clang++ "${tgt[@]}" "${cxxinc[@]}" "${eh[@]}" -c "$root/tests/macos-sysroot/runtime/src/eh_glue.cpp" -o eh_glue.o

rm -f libnfcxx-darwin-rt.a
# The runtime archive. cxa_handlers.o and cxa_default_handlers.o replace EDG's terminate and unexpected handlers (libc_drop
# below). std::exception, bad_alloc, bad_cast and type_info stay in EDG's libC.a: the exception.cpp and stdlib_exception.cpp
# copies would duplicate or undercut them (see above), and the stdlib_typeinfo and private_typeinfo members would duplicate
# EDG's ___dynamic_cast. Members that libC.a still owns (stdlib_new_delete, ...) are built but not archived, as before.
clang "${tgt[@]}" "${inc[@]}" -O2 -c "$root/tests/macos-sysroot/runtime/src/xlocale_shim.c" -o xlocale_shim.o
# The classic rune table libc++ reads for ctype<char> on Apple (locale.cpp under _LIBCPP_HAS_DEFAULTRUNELOCALE).
clang "${tgt[@]}" "${inc[@]}" -O2 -c "$root/tests/macos-sysroot/runtime/src/rune_default.c" -o rune_default.o
llvm-ar rcs libnfcxx-darwin-rt.a streambuf_seekpos.o xlocale_shim.o rune_default.o atomic.o atomic_fetch.o abort_message.o cxa_exception.o cxa_handlers.o cxa_exception_storage.o cxa_personality.o fallback_malloc.o eh_glue.o cxa_default_handlers.o
echo "built $out/libnfcxx-darwin-rt.a from llvm-project $pin"

# libc++ itself, built from LLVM's own sources at the pin with the cross clang (not a hand-written subset), into a
# separate archive. _LIBCPP_NO_ABI_TAG keeps the names untagged, which matches the Mac's libc++ spellings. The config
# site is ours (tests/macos-sysroot/cxx/__config_site); the headers and sources are LLVM's at the pin.
# __assertion_handler is generated by libc++'''s CMake from vendor/llvm/default_assertion_handler.in (a plain copy: the
# template has no placeholders), so the copy is made here and its directory is searched before the libc++ headers.
mkdir -p libcxx-gen
cp "$src/libcxx/vendor/llvm/default_assertion_handler.in" libcxx-gen/__assertion_handler
# The copy keeps the headers in one place for the libc++ build below. __config is used as LLVM ships it: on Apple it
# defines _LIBCPP_HAS_DEFAULTRUNELOCALE, and locale.cpp then reads _DefaultRuneLocale, which rune_default.c provides.
rm -rf libcxx-include && cp -R "$src/libcxx/include" libcxx-include
cxxlib=(-nostdinc -nostdinc++ -isystem "$root/tests/macos-sysroot/cxx" -isystem "$out/libcxx-gen" -isystem "$out/libcxx-include" -isystem "$NFCXX_MACOS_SYSROOT"
        -isystem "$(clang -print-resource-dir)/include" -I "$src/libcxxabi/include" -I "$src/libcxx/src")
# -mmacosx-version-min=11.0: aligned new/delete are available from 10.13, and arm64 Darwin starts at 11.0.
# -U__ENVIRONMENT_*: refstring.h adds a check for libstdc++'s empty-string singleton (only for a process that also
# loads libstdc++, which none of our programs do) and includes mach-o/dyld.h, which is not a clean-room header.
cxxlibdefs=(-D_LIBCPP_BUILDING_LIBRARY -D_LIBCPP_NO_ABI_TAG -D_LIBCXXABI_BUILDING_LIBRARY -mmacosx-version-min=11.0
            -U__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ -U__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)
# Excluded: tz.cpp (its path is #error on any non-Linux host, and libc++ 18 has no config switch for it) and chrono.cpp
# (its Apple branch needs CLOCK_MONOTONIC_RAW, which is not a POSIX name and is not in the clean-room headers). The
# names they define are left to the link check to report.
# Also excluded: the three filesystem sources that include dirent.h (directory_entry, directory_iterator, operations). The
# dirent layout is not defined by POSIX; it would have to come from the target, which is not read here.
# exception.cpp is left out for now. Its std::exception family would replace EDG's exception.o and bad_alloc.o, but EDG's
# typeinfo.o (bad_cast) calls std::exception's constructors out-of-line, and libc++abi's stdlib_exception.o does not define
# them (the libc++ headers make them inline), so those members cannot move without undefined references. The terminate
# family is the part that moves (libc_drop below). locale.cpp is built: its rune table is rune_default.c above.
libcxx_skip=" tz.cpp chrono.cpp directory_entry.cpp directory_iterator.cpp operations.cpp exception.cpp "
mkdir -p libcxx-obj
rm -f libc++-darwin.a libcxx-obj/*.o
cxxlib_fail=0
for f in "$src"/libcxx/src/*.cpp "$src"/libcxx/src/filesystem/*.cpp; do
  [ -f "$f" ] || continue
  case "$libcxx_skip" in *" $(basename "$f") "*) continue;; esac
  o="libcxx-obj/$(basename "$(dirname "$f")")_$(basename "$f" .cpp).o"
  if ! clang++ "${tgt[@]}" "${cxxlib[@]}" "${cxxlibdefs[@]}" -std=c++20 -fexceptions -O2 -c "$f" -o "$o" 2>"libcxx-obj/$(basename "$f" .cpp).err"; then
    echo "build.sh: libc++ source did not compile: $f" >&2; cxxlib_fail=$((cxxlib_fail+1))
  fi
done
[ "$cxxlib_fail" = 0 ] || { echo "build.sh: $cxxlib_fail libc++ sources failed; see build/macos-rt/libcxx-obj/*.err" >&2; exit 1; }
ls libcxx-obj/*.o >/dev/null 2>&1 && llvm-ar rcs libc++-darwin.a libcxx-obj/*.o && echo "built $out/libc++-darwin.a ($(ls libcxx-obj/*.o | wc -l) objects)"
# libC-darwin.a is EDG's libC.a without eh_util.o: std::terminate, get/set_terminate, std::unexpected, set_unexpected and
# uncaught_exception(s) are defined by the archives built here (cxa_handlers.o, cxa_default_handlers.o, and eh_glue.o for the
# uncaught functions and the names the EH runtime calls). The EH entry points (throw.o: __curr_eh_stack_entry, the EH shim
# members), exception.o, bad_alloc.o, typeinfo.o, rtti.o, vars.o and vec_newdel.o stay in libC.a.
# A dropped symbol that a remaining member refers to must come from one of the two archives built here; otherwise the link of
# such a program would fail, so the build stops with the list.
libc_in=${NFCXX_MACOS_LIBC:-$root/build/edg-cross/lib/libC.a}
libc_drop="eh_util.o"
cp "$libc_in" libC-darwin.a
llvm-ar d libC-darwin.a $libc_drop
drop_syms=$(for m in $libc_drop; do llvm-nm -A --defined-only -g "$libc_in" | grep -E ":$m: " ; done | awk '{print $NF}' | sort -u)
refs=$(llvm-nm -A -u libC-darwin.a libnfcxx-darwin-rt.a libc++-darwin.a | awk '{print $NF}' | sort -u)
provided=$( (llvm-nm -A --defined-only -g libc++-darwin.a; llvm-nm -A --defined-only -g libnfcxx-darwin-rt.a) | awk '{print $NF}' | sort -u)
missing=$(comm -23 <(comm -12 <(printf '%s\n' "$drop_syms") <(printf '%s\n' "$refs")) <(printf '%s\n' "$provided") || true)
if [ -n "$missing" ]; then
  echo "build.sh: symbols of the dropped libC.a members that a remaining member needs and no archive provides:" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi
echo "built $out/libC-darwin.a (libC.a without $libc_drop; $(printf '%s\n' "$drop_syms" | wc -l) dropped symbols)"

# The LLVM sources are removed only now, after the libc++ step that reads them.
rm -rf "$llvm"
