#!/usr/bin/env bash
# Path B long double support library (be/nfcxx_ldrt.c, docs/notes/pathb-longdouble.md). Prints the path of libnfcxxld.a,
# building it with the host C compiler first when it is missing or older than its source. Every Path B link step adds
# the archive after its objects: $(scripts/pathb-ldrt) (the archive only pulls in the helpers a program calls).
# PATHB_LDRT_OUT: build somewhere else (default build/pathb-ldrt).
# NFCXX_LDRT_X86=1: the x86-64 variant of the checked float-to-integer conversions (saturating, as gcc on x86-64, instead of
# the abort), built into build/pathb-ldrt-x86 unless PATHB_LDRT_OUT is set. Only the stage-2 front end links it
# (scripts/selfhost-cpfe.rb); user programs keep the trap.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${PATHB_LDRT_OUT:-$root/build/pathb-ldrt}
defines=
if [ "${NFCXX_LDRT_X86:-0}" = 1 ]; then
  out=${PATHB_LDRT_OUT:-$root/build/pathb-ldrt-x86}
  defines=-DNFCXX_FLOAT_TO_INT_X86
fi
# NFCXX_GCC names cosmocc with --cosmo: the archive is cosmo's own (build/pathb-ldrt-cosmo), built by that compiler.
cc_bin=${NFCXX_GCC:-cc}
case $cc_bin in *cosmocc*) out=${PATHB_LDRT_OUT:-$root/build/pathb-ldrt-cosmo} ;; esac
src=$root/be/nfcxx_ldrt.c
lib=$out/libnfcxxld.a
if [ ! -f "$lib" ] || [ "$src" -nt "$lib" ]; then
  mkdir -p "$out"
  tmp=$(mktemp -d "$out/.tmp.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  # -ffunction-sections: one helper per archive member would be better, but one object keeps the link line trivial
  "$cc_bin" -O2 -fno-strict-aliasing -fPIC $defines -c -o "$tmp/nfcxx_ldrt.o" "$src"
  ar rcs "$tmp/libnfcxxld.a" "$tmp/nfcxx_ldrt.o"
  mv "$tmp/libnfcxxld.a" "$lib"
fi
# A harness with exception tables (eh-tables beside its cpfe): a GNU ld input script in place of the archive, which puts
# libstdc++ and libgcc_s ahead of the libC.a every Path B link names after it (docs/notes/pathb-zero-cost-eh.md).
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
if [ -f "$(dirname "$cpfe")/eh-tables" ] && case $cc_bin in *cosmocc*) false ;; *) true ;; esac && [ "$(uname -s)" != Darwin ]; then
  script=$out/libnfcxxld-eh.ld
  text="/* nfcxx: scripts/pathb-ldrt.rb, a Path B link with exception tables (docs/notes/pathb-zero-cost-eh.md) */
INPUT ( $lib -lstdc++ -lgcc_s )"
  if [ ! -f "$script" ] || [ "$(cat "$script")" != "$text" ]; then
    printf '%s\n' "$text" > "$script.$$"
    mv "$script.$$" "$script"
  fi
  lib=$script
fi
echo "$lib"
