#!/usr/bin/env bash
# Build mrustc (thepowersgang/mrustc, the commit pinned below) and its Rust 1.90.0 standard library into
# build/mrustc/src, for scripts/mrustc-nfcc.sh. The first run downloads the rustc 1.90.0 source (about 270 MB) and
# takes a few minutes on 4 cores. Does nothing if the library is built already.
#   FORCE=1        rebuild the compiler and the library
#   PARLEVEL=<n>   parallel jobs (default: the number of CPUs)
# Needs the mrustc build dependencies: a C++14 compiler, GNU make, patch, curl, pkg-config and libz (see its README).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD; work=$root/build/mrustc; src=$work/src
# take-cheeze/mrustc, branch nfcxx/mold3: nfcxx/patches 2dfe9ccb (the tracking branch: nfcxx/fixes, upstream
# thepowersgang/mrustc d85e86b plus nfcxx's fixes, plus the open bug PRs) and the fixes that build mold 3 (bugs 22 to 41 of
# NFCXX-FIXES.md, one commit each). MRUSTC_REPO overrides the repository.
url=${MRUSTC_REPO:-https://github.com/take-cheeze/mrustc}
pin=f9dea5d4
jobs=${PARLEVEL:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}

if [ "${FORCE:-}" != 1 ] && [ -x "$src/bin/mrustc" ] && [ -f "$src/output-1.90.0/libstd.rlib.o" ]; then
  exit 0
fi
if [ ! -d "$src/.git" ]; then
  mkdir -p "$work"
  rm -rf "$src"
  git clone --quiet "$url" "$src"
fi
git -C "$src" checkout --quiet "$pin"

# The steps of mrustc's build-1.90.0.sh: the compiler, the rustc source, then the libraries (core, alloc, std, ...).
export RUSTC_VERSION=1.90.0 MRUSTC_TARGET_VER=1.90 OUTDIR_SUF=-1.90.0 MINICARGO_DEFER_CODEGEN=1 PARLEVEL=$jobs
make -C "$src" -j"$jobs"
make -C "$src" RUSTCSRC
make -C "$src" -f minicargo.mk LIBS
echo "setup-mrustc: $src/bin/mrustc and $src/output-1.90.0 built"
