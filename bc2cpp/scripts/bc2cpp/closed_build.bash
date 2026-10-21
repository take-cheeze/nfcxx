#!/usr/bin/env bash
# Build build_config.rb's `closed` mruby library with bc2cpp: the closed world
# (RPG2000/2003 only) compiled natively by the host compiler, with mruby's
# C++-exception mode on (docs/ci.md, "bc2cpp gate").
#
# bc2cpp's generated C++ lowers block `break`, non-local `return` and `raise`
# with real C++ throw/catch, so it needs MRB_USE_CXX_EXCEPTION. This build
# checks the closed world's generation and the compilation of the generated
# code.
#
# Usage:
#   scripts/bc2cpp/closed_build.bash [BUILD_DIR, default ./build-closed-bc2cpp]
#
# Needs on PATH: ruby, rake, a native C/C++ compiler, bison, gperf, curl and
# python3 (scripts/mruby/standalone_prep.bash). No cross toolchain. Writes
# BUILD_DIR/closed/lib/libmruby.a and the bootstrap BUILD_DIR/host mrbc.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${1:-$root/build-closed-bc2cpp}"
# Tools, Unicode tables and mruby patches.
# shellcheck source=scripts/mruby/standalone_prep.bash
. "$root/scripts/mruby/standalone_prep.bash"
# The compiled gems need C++ exceptions; build_config.rb's `closed` stanza
# enables them, and this escape hatch would turn them off in the host half.
unset MRUBY_FORCE_NO_CXX_EXCEPTION
cd "$root/3rd/mruby"
MRUBY_CONFIG="$root/build_config.rb" \
  MRUBY_BUILD_DIR="$build_dir" \
  PROJECT_BUILD_DIR="$build_dir" \
  MRUBY_TARGET=closed \
  RPGMAKER_BC2CPP=1 \
  rake

echo "built $build_dir/closed/lib/libmruby.a"

# mruby-rgss's lib.cxx includes shinonome.hxx, which its rake file writes into the RGSS build directory. The base
# generator looks for it under closed/mrbgems/mruby-rgss (base_rbs_all.rb flags_for), so write it there as well.
jis0208_table="${jis0208_table:-$root/.native-build-tables/JIS0208.TXT}"
[ -f "$jis0208_table" ] || {
  echo "error: missing $jis0208_table (scripts/native/build-without-nix.bash fetches it)" >&2
  exit 1
}
rgss_dir="$build_dir/closed/mrbgems/mruby-rgss"
mkdir -p "$rgss_dir"
(cd "$rgss_dir" && jis0208_table="$jis0208_table" ruby "$root/mruby-rgss/gen_shinonome_data.rb" > /dev/null)
echo "wrote $rgss_dir/shinonome.hxx"
