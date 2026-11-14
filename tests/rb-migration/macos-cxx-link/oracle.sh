#!/usr/bin/env bash
# macos-cxx-link.sh SRC.cpp OUT [NFCXX_OPTION...]: a Mach-O arm64 link of one C++ source from this Linux host, with the prelinker run
# (template instances are generated and compiled through the Darwin C path). The cross EDG base (build/edg-base-cross,
# llvm-nm for Mach-O) and build/cross-macos.env must be in place (scripts/setup-cross-macos.sh). Not run: nothing is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2; shift 2; extra=("$@")   # extra: nfcxx options for both steps, e.g. -I DIR and -DNAME=VALUE
. "$root/build/cross-macos.env"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
sysincl="$NFCXX_MACOS_CLEANROOM/cxx:$NFCXX_LIBCXX:$NFCXX_MACOS_SYSROOT"
# 1. compile: the object and its .ii/.ti records (the template requests) beside it; the Darwin C path compiles the C
NFCXX_CC="$root/scripts/cross-macos-cc.sh" NFCXX_CXX="$root/scripts/cross-macos-cxx.sh" NFCXX_SYS_INCLUDES="$sysincl" \
  "$root/nfcxx" -c ${extra[@]+"${extra[@]}"} "$src" -o tl.o
# 2. link: the prelinker reads tl.ii/.ti, compiles the instances through NFCXX_CC, and eccp links with the stub linker
NFCXX_CC="$root/scripts/cross-macos-cc.sh" NFCXX_CXX="${NFCXX_LINK_DIALECT:-$root/scripts/cross-macos-cxx.sh}" NFCXX_SYS_INCLUDES="$sysincl" \
  EDG_OBJ_TO_EXEC_LINKER="$root/scripts/cross-macos-link.sh" \
  "$root/nfcxx" ${extra[@]+"${extra[@]}"} tl.o -o exe
mkdir -p "$(dirname "$out")"; cp exe "$out"
