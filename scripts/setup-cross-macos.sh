#!/usr/bin/env bash
# setup-cross-macos.sh: prepare a Linux host to compile (not link or run) C and C++ for macOS arm64 with nfcxx.
# Checks the tools, builds what is missing (EDG, QBE and cproc for this host), and writes build/cross-macos.env, which
# scripts/cross-macos-check.sh sources. Idempotent: a second run builds nothing and rewrites the same file.
# The configuration only affects the commands that source build/cross-macos.env; the default Linux build is unchanged.
# See docs/notes/cross-macos.md for what it covers.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
llvm=${NFCXX_LLVM:-/usr/lib/llvm-18}

[ "$(uname -s)" = Linux ] || { echo "setup-cross-macos: this configuration is for a Linux host (uname says $(uname -s))" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "setup-cross-macos: missing $1: $2" >&2; exit 1; }; }
need clang "install clang-18 (apt install clang-18 and make clang the default, or put it on PATH)"
need cmake "apt install cmake ninja-build (EDG is built with cmake)"
need ninja "apt install ninja-build"
[ -x "$llvm/bin/llvm-mc" ] || { echo "setup-cross-macos: missing $llvm/bin/llvm-mc (apt install llvm-18)" >&2; exit 1; }
[ -x "$llvm/bin/ld64.lld" ] || { echo "setup-cross-macos: missing $llvm/bin/ld64.lld (apt install lld-18)" >&2; exit 1; }
libcxx=${NFCXX_LIBCXX:-$llvm/include/c++/v1}
[ -f "$libcxx/__config" ] || { echo "setup-cross-macos: libc++ headers not found at $libcxx (apt install libc++-18-dev)" >&2; exit 1; }
[ -f "$root/tests/macos-sysroot/include/stdio.h" ] || { echo "setup-cross-macos: the clean-room sysroot is missing (tests/macos-sysroot)" >&2; exit 1; }

# Build only what is missing: a second run skips these, so it is a no-op apart from rewriting the env file.
if [ -x "$root/build/edg/bin/cpfe" ]; then echo "EDG: already built"; else "$root/scripts/setup-edg.sh"; fi
if [ -x "$root/build/qbe/qbe" ] && [ -x "$root/build/cproc/cproc-qbe" ]; then
  echo "QBE and cproc: already built"
else
  "$root/scripts/setup-qbe.sh"
fi

# The prelinker runs `nm` on the objects it reads at link time. On a Linux host the EDG base's default is GNU `nm -og`,
# which cannot read Mach-O (its symbol values are 16 hex digits), so it stops reading and the template instances are
# never generated. The cross path therefore gets its own EDG tree and base: llvm-nm reads the Mach-O objects, and
# -fMacOSX64 is the prelinker's option for that output, and -u makes it strip the Mach-O leading underscore from
# the symbol names it matches (the instance is __Z..., the prelinker looks for _Z...) (as scripts/setup-edg.sh sets it for a macOS host). The native
# Linux tree (build/edg, build/edg-base) is not touched.
# The cross front end is built from the macOS arm64 EDG base (NFCXX_EDG_TARGET=macos-arm64, scripts/setup-edg.sh), not
# from the Linux base: the Linux front end defines __linux__ and __GLIBC__, so libc++'s __config takes its glibc branch
# and includes features.h. The macOS base's predefined macros are Darwin's. Its tree and base are the cross-only
# build/edg-cross and build/edg-base-cross; the native Linux tree (build/edg, build/edg-base) is not touched.
cross_edg="$root/build/edg-cross"; cross_base="$root/build/edg-base-cross"
if [ ! -x "$cross_edg/bin/eccp" ]; then
  rm -rf "$cross_edg" "$cross_base"
  NFCXX_EDG_TARGET=macos-arm64 EDG_BUILD="$cross_edg" EDG_BASE="$cross_base" "$root/scripts/setup-edg.sh"
  # The prelinker reads the instance symbols with nm. On a Linux host, plain nm cannot read Mach-O objects, so use
  # llvm-nm. The macOS base already passes -fMacOSX64 (the 16-digit Mach-O values) to the prelinker. -u strips the Mach-O
  # leading underscore from the names it matches (the instance is __Z..., the prelinker looks for _Z...).
  sed -i 's|-c "nm -og 2>/dev/null" -fMacOSX64 |-c "llvm-nm -og 2>/dev/null" -fMacOSX64 -u |' "$cross_base/edg_eccp_config"
fi
grep -q 'llvm-nm -og 2>/dev/null" -fMacOSX64 -u' "$cross_base/edg_eccp_config" || { echo "setup-cross-macos: $cross_base does not have the Mach-O prelink option" >&2; exit 1; }

mkdir -p "$root/build"
cat > "$root/build/cross-macos.env" <<EOF
# Written by scripts/setup-cross-macos.sh. Source this to run the macOS arm64 compile checks on this Linux host.
export NFCXX_MACOS_CLEANROOM="$root/tests/macos-sysroot"
export NFCXX_MACOS_SYSROOT="$root/tests/macos-sysroot/include"
# Opt-in: the EDG C++ runtime for arm64 Darwin (scripts/setup-edg.sh, NFCXX_EDG_TARGET=macos-arm64). Setting
# NFCXX_MACOS_LIBC to build/edg/lib/libC.a links it into the C++ cross links; it is off by default, because the test
# programs that use the standard streams do not link with it yet (see the notes in docs/notes/cross-macos.md).
export NFCXX_LIBCXX="$libcxx"
export EDG_BUILD="$root/build/edg-cross"
export EDG_BASE="$root/build/edg-base-cross"
export PATH="$llvm/bin:\$PATH"
EOF
echo "wrote $root/build/cross-macos.env"
