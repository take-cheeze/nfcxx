#!/usr/bin/env bash
# macos-cxx-link.sh SRC.cpp OUT: a Mach-O arm64 link of one C++ source from this Linux host, with the prelinker run
# (template instances are generated and compiled through the Darwin C path). The cross EDG base (build/edg-base-cross,
# llvm-nm for Mach-O) and build/cross-macos.env must be in place (scripts/setup-cross-macos.sh). Not run: nothing is executed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2
. "$root/build/cross-macos.env"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"
sysincl="$NFCXX_MACOS_CLEANROOM/cxx:$NFCXX_LIBCXX:$NFCXX_MACOS_SYSROOT"
# NFCXX_CXX_FLAGS (for example -I for a project header or -DX=1) reach the compile step and the prelinker's instance
# compiles through a wrapper, as macos-cxx-check.sh passes them to its preprocess. The wrapper expands the variable at run time.
flagcxx="$work/clang-cxx"
printf '#!/bin/sh\nexec clang++ "$@" $NFCXX_CXX_FLAGS\n' > "$flagcxx"; chmod +x "$flagcxx"
# 1. compile: the object and its .ii/.ti records (the template requests) beside it; the Darwin C path compiles the C
NFCXX_CC="$root/scripts/cross-macos-cc.sh" NFCXX_CXX="$flagcxx" NFCXX_SYS_INCLUDES="$sysincl" \
  "$root/nfcxx" -c "$src" -o tl.o
# 2. link: the prelinker reads tl.ii/.ti, compiles the instances through NFCXX_CC, and eccp links with the stub linker
NFCXX_CC="$root/scripts/cross-macos-cc.sh" NFCXX_CXX="${NFCXX_LINK_DIALECT:-$flagcxx}" NFCXX_SYS_INCLUDES="$sysincl" \
  EDG_OBJ_TO_EXEC_LINKER="$root/scripts/cross-macos-link.sh" \
  "$root/nfcxx" tl.o -o exe
cp exe "$out"
