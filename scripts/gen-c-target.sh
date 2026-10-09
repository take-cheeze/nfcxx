#!/usr/bin/env bash
# Generate the C that the EDG front end emits for a chosen (non-host) target configuration,
# without compiling it. The target picks the predefined-macro table (build/edg-base/lib_<target>)
# and the sizes/alignments EDG uses for layout, so this is the C to hand to a cross compiler.
#
# Usage: scripts/gen-c-target.sh [-t TARGET] [-std=c++NN] [-o out.c] file.cpp
#   TARGET defaults to linux_riscv32 (ILP32, little-endian, the closest EDG config to Hexagon;
#   see docs/notes/hexagon.md). Other choices: linux_i686 (32-bit x86, not ABI-exact, see notes),
#   linux_armv7, win32. Without -o the C goes to stdout.
# Needs build/edg (scripts/setup-edg.sh). cpfe runs from the base dir, as the nfcxx driver does.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
edg=${EDG_BUILD:-$root/build/edg}/bin
base=${EDG_BASE:-$root/build/edg-base}

target=linux_riscv32; std=--c++23; out=""; src=""
while [ $# -gt 0 ]; do
  case $1 in
    -t|--target) target=$2; shift ;;
    --target=*) target=${1#--target=} ;;
    -std=c++*) std=--c++${1#-std=c++} ;;
    -o) out=$2; shift ;;
    -*) echo "gen-c-target: unknown option $1" >&2; exit 2 ;;
    *) src=$1 ;;
  esac
  shift
done
[ -n "$src" ] || { echo "usage: $0 [-t TARGET] [-std=c++NN] [-o out.c] file.cpp" >&2; exit 2; }
[ -x "$edg/cpfe" ] || { echo "gen-c-target: cpfe not built; run scripts/setup-edg.sh" >&2; exit 2; }
[ -d "$base/lib_$target" ] || { echo "gen-c-target: no predefined macros for target '$target' in $base" >&2; exit 2; }

src=$(realpath "$src")
# setup-edg.sh copies the base dir with a relative `include` symlink that dangles in build/edg-base;
# use the real EDG header directory in that case.
inc=$base/include
[ -e "$inc/exception.h" ] || inc=$root/3rd/edg/include_c++
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(cd "$base" && "$edg/cpfe" -D_POSIX_SOURCE -D__CHAR_BIT__=8 "$std" --g++ --target "$target" \
    --sys_include="$inc" --gen_c_file_name="$tmp/out.c" "$src")
if [ -n "$out" ]; then cp "$tmp/out.c" "$out"; else cat "$tmp/out.c"; fi
