#!/usr/bin/env bash
# Build a scratch EDG that has a real `linux_hexagon` target (docs/notes/hexagon.md, section 2).
# 3rd/edg ships no Hexagon target, so this copies the submodule to build/edg-src-hex
# (the submodule stays clean), adds the target, and builds it with setup-edg.sh.
#
# What the target is: a copy of linux_riscv32 with long double as IEEE double
# (size/align 8, LDBL = DBL constants), everything else identical, registered as
# target configuration #8. Verified: tests/hexagon/layout.sh passes, long double
# cases generate 8-byte layout, and the hexagon suite matches the riscv32 results.
#
# Overrides: EDG_HEX_SRC (scratch source, default build/edg-src-hex),
# EDG_HEX_BUILD (output, default build/edg-hex), EDG_HEX_BASE (base dir,
# default build/edg-hex-base). CLANG picks the compiler for the macro table.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=${EDG_HEX_SRC:-$root/build/edg-src-hex}
out=${EDG_HEX_BUILD:-$root/build/edg-hex}
base=${EDG_HEX_BASE:-$root/build/edg-hex-base}
clang=${CLANG:-clang-19}

if [ ! -f "$root/3rd/edg/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

if [ ! -f "$src/CMakeLists.txt" ]; then
  echo "setup-edg-hexagon: copying 3rd/edg to $src" >&2
  rm -rf "$src"
  cp -a "$root/3rd/edg" "$src"
  rm -f "$src/.git"
fi

# 1. The target configuration (copy of linux_riscv32, long double as IEEE double).
mkdir -p "$src/cmake/macro-conf/support/target/linux_hexagon"
sed -e 's/linux_riscv32/linux_hexagon/g' \
  -e 's/^TARG_ALIGNOF_LONG_DOUBLE_linux_hexagon=16$/TARG_ALIGNOF_LONG_DOUBLE_linux_hexagon=8/' \
  -e 's/^TARG_LONG_DOUBLE_FIELD_ALIGNMENT_linux_hexagon=16$/TARG_LONG_DOUBLE_FIELD_ALIGNMENT_linux_hexagon=8/' \
  -e 's/^TARG_SIZEOF_LONG_DOUBLE_linux_hexagon=16$/TARG_SIZEOF_LONG_DOUBLE_linux_hexagon=8/' \
  -e 's/^TARG_LDBL_MANT_DIG_linux_hexagon=113$/TARG_LDBL_MANT_DIG_linux_hexagon=53/' \
  -e 's/^TARG_LDBL_MAX_EXP_linux_hexagon=16384$/TARG_LDBL_MAX_EXP_linux_hexagon=1024/' \
  -e 's/^TARG_LDBL_MIN_EXP_linux_hexagon=(-16381)$/TARG_LDBL_MIN_EXP_linux_hexagon=(-1021)/' \
  -e 's/^TARG_SUPPORTS_RISCV32_linux_hexagon=1$/TARG_SUPPORTS_RISCV32_linux_hexagon=0/' \
  "$root/3rd/edg/cmake/macro-conf/support/target/linux_riscv32/base.cmakedef" \
  > "$src/cmake/macro-conf/support/target/linux_hexagon/base.cmakedef"

# 2. Register it as target configuration #8 (the platform file is otherwise untouched).
plat="$src/cmake/macro-conf/support/platform/linux-x86_64/base.cmakedef"
if ! grep -q "TARGET_CONFIGURATION_8=linux_hexagon" "$plat"; then
  cat >> "$plat" <<'EOF'

# Import the named linux_hexagon target as target configuration #8
import <support/target/linux_hexagon/base>
TARGET_CONFIGURATION_8=linux_hexagon
EOF
fi

# 3. Build cpfe/edg_prelink/libC.a the way setup-edg.sh does.
EDG_SRC="$src" EDG_BUILD="$out" EDG_BASE="$base" "$root/scripts/setup-edg.sh"

# 4. The predefined-macro table from clang's Hexagon target (setup-edg.sh wipes $base first).
mkdir -p "$base/lib_linux_hexagon"
"$root/scripts/hexagon-predef.rb" "$base/lib_linux_hexagon/predefined_macros.txt" "$clang"

echo "setup-edg-hexagon: EDG_BUILD=$out EDG_BASE=$base (use with -t linux_hexagon)" >&2
