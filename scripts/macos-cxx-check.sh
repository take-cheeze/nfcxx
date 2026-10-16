#!/usr/bin/env bash
# macos-cxx-check.sh SRC.cpp OUT.s: a compile check of one C++ source for macOS arm64 from any host, through nfcxx's
# front end and the Darwin C path (scripts/qbe-cc). It stops at assembly: nothing is linked or run.
#   1. clang preprocesses SRC for arm64-apple-darwin against the clean-room sysroot (tests/macos-sysroot) and the
#      libc++ headers (NFCXX_LIBCXX, default LLVM 18's, from libc++-18-dev). clang chooses the headers and the #if
#      branches: the EDG front end defines __linux__ itself, and libc++'s __config would follow it to glibc's features.h.
#   Blocks (Apple's ^ syntax) are off here, as setup-edg.sh has them off for EDG: libc++ checks __has_extension(blocks).
#   2. nfcxx --emit-c reads that text with clang's dialect (NFCXX_CXX=clang++, so EDG's clang builtins apply) and only
#      the sysroot's directories as system includes, so no host header is reached.
#   3. scripts/qbe-cc -S compiles the generated C for the Darwin target (NFCXX_MACOS_SYSROOT).
# Not covered: the EDG front end still lays out types for its build host (Linux, long double 128-bit) and the
# clang builtins EDG does not know are not all handled. A pass means the source reached assembly, not ABI parity.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=$1; out=$2
sysroot=${NFCXX_MACOS_SYSROOT:-$root/tests/macos-sysroot}
libcxx=${NFCXX_LIBCXX:-/usr/lib/llvm-18/include/c++/v1}
[ -d "$libcxx" ] || { echo "macos-cxx-check: libc++ headers not found at $libcxx (set NFCXX_LIBCXX; the container has libc++-18-dev)" >&2; exit 2; }
clangres=$(clang -print-resource-dir)/include
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
clang++ --target=arm64-apple-darwin -std=c++17 -E -fno-blocks -U__BLOCKS__ -nostdinc++ -nostdinc \
  -isystem "$sysroot/cxx" -isystem "$libcxx" -isystem "$sysroot/include" -isystem "$clangres" \
  "$src" -o "$tmp/pp.ii"
NFCXX_CXX=clang++ NFCXX_SYS_INCLUDES="$sysroot/cxx:$libcxx:$sysroot/include" \
  "$root/nfcxx" --emit-c "$tmp/pp.ii" > "$tmp/gen.c"
NFCXX_MACOS_SYSROOT="$sysroot/include" "$root/scripts/qbe-cc" -S "$tmp/gen.c" -o "$out"
