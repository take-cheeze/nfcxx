#!/usr/bin/env bash
# Linker for the macOS arm64 cross C++ link (EDG_OBJ_TO_EXEC_LINKER, scripts/macos-cxx-link.sh): eccp's gcc-style link line
# becomes an ld64.lld call against the clean-room stubs (tests/macos-sysroot/lib). The objects and -o are kept; compile-only
# options, the host runtime (-lC, -lstdc++, -lgcc*, -lm, -lc, -lpthread, -ldl) and -rpath are dropped. Mach-O only: nothing
# here runs the output. A link that needs a symbol the stubs lack fails in the stub check, as before.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stub="$root/tests/macos-sysroot/lib"
out=a.out; objs=(); libdirs=(); libs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -o*) out=${1#-o} ;;
    -L) libdirs+=("$2"); shift ;;
    -L*) libdirs+=("${1#-L}") ;;
    -l*) case "${1#-l}" in C|stdc++|gcc|gcc_s|m|c|pthread|dl|rt) ;; *) libs+=("$1") ;; esac ;;
    -Wl,*) ;;
    -O*|-f*|-g*|-W*|-m*|-pipe|-c|-shared|-rdynamic|-fPIC|-pic) ;;
    *.o|*.a)
      # the driver adds the host-built sret thunks (ELF); they are not Mach-O and not needed by the programs here
      case "$(file -b "$1" 2>/dev/null)" in *ELF*) echo "cross-macos-link: dropped host object $1 (not Mach-O)" >&2 ;; *) objs+=("$1") ;; esac ;;
    *) ;;
  esac
  shift
done
# The open-source compiler and libc++abi runtime (tests/macos-sysroot/runtime, built by build.sh): the sized __atomic_*
# calls, the aligned operator new and delete, __cxa_pure_virtual and the __cxa_vec_* helpers. Added only when built.
rt=${NFCXX_MACOS_RT:-$root/build/macos-rt/libnfcxx-darwin-rt.a}
# EDG's libC.a without the exception, typeinfo and terminate members that libc++ and libc++abi provide (build.sh writes
# libC-darwin.a from it); the raw libC.a is used only when that archive has not been built.
libc=${NFCXX_MACOS_LIBC:-}; libcb=$root/build/macos-rt/libC-darwin.a; [ -f "$libcb" ] && libc=$libcb
libcargs=(); [ -n "$libc" ] && [ -f "$libc" ] && libcargs=("$libc")
# The libc++ built from the open-source sources (tests/macos-sysroot/runtime/build.sh). Linked before -lc++, so its definitions
# are used when it is built; the system libc++ supplies the rest at run time.
cxxb=${NFCXX_MACOS_LIBCXX_BUILT:-$root/build/macos-rt/libc++-darwin.a}; cxxbargs=(); [ -f "$cxxb" ] && cxxbargs=("$cxxb")
rtargs=(); [ -f "$rt" ] && rtargs=("$rt")
exec ld64.lld --error-limit=0 -arch arm64 -platform_version macos 11.0 11.0 -o "$out" "${objs[@]}" ${libcargs[@]+"${libcargs[@]}"} ${rtargs[@]+"${rtargs[@]}"} ${cxxbargs[@]+"${cxxbargs[@]}"} \
  -L "$stub" -lSystem -L "$stub" -lc++ ${libs[@]+"${libs[@]}"}
