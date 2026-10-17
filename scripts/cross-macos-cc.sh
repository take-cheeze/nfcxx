#!/usr/bin/env bash
# C compiler for the macOS arm64 cross build of the EDG runtime (scripts/setup-edg.sh with NFCXX_EDG_TARGET=macos-arm64):
# clang for arm64-apple-darwin against the clean-room headers in NFCXX_MACOS_SYSROOT, which emits Mach-O objects.
# clang rather than QBE here: the front end writes _Float16 constants as F16, which cproc does not accept.
set -euo pipefail
: "${NFCXX_MACOS_SYSROOT:?set NFCXX_MACOS_SYSROOT to the clean-room include directory}"
exec clang --target=arm64-apple-darwin -nostdinc -isystem "$NFCXX_MACOS_SYSROOT" -isystem "$(clang -print-resource-dir)/include" "$@"
