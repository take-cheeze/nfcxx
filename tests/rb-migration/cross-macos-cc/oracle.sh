#!/usr/bin/env bash
# C compiler for the macOS arm64 cross C++ link (scripts/macos-cxx-link.sh): clang for arm64-apple-darwin against the
# clean-room headers in NFCXX_MACOS_SYSROOT, which emits Mach-O objects. It is EDG_C_TO_OBJ_COMPILER (NFCXX_CC) for the
# compile of the prelinker's template instances. Options that only gcc takes are dropped here.
set -euo pipefail
: "${NFCXX_MACOS_SYSROOT:?set NFCXX_MACOS_SYSROOT to the clean-room include directory}"
args=()
for a in "$@"; do
  case "$a" in
    -fkeep-static-functions|-fwrapv|-fno-strict-aliasing|-fgnu89-inline) ;;
    *) args+=("$a") ;;
  esac
done
# The front end emits the standard streams as extern globals named stdin, stdout and stderr; Darwin's libc names them
# __stdinp and friends (the stdio.h macros in the clean-room headers do the same).
exec clang --target=arm64-apple-darwin -nostdinc -isystem "$NFCXX_MACOS_SYSROOT" -isystem "$(clang -print-resource-dir)/include" \
  -Dstdin=__stdinp -Dstdout=__stdoutp -Dstderr=__stderrp ${args[@]+"${args[@]}"}
