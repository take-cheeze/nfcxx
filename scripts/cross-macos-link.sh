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
    *.o|*.a) objs+=("$1") ;;
    *) ;;
  esac
  shift
done
exec ld64.lld -arch arm64 -platform_version macos 11.0 11.0 -o "$out" "${objs[@]}" \
  -L "$stub" -lSystem -L "$stub" -lc++ ${libs[@]+"${libs[@]}"}
