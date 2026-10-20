#!/usr/bin/env bash
# Build the EDG C++ front end (Apache 2.0, submodule at 3rd/edg) out of tree into
# build/edg. Builds only the host tools nfcxx needs: cpfe (front end), edg_prelink
# (template instantiation), libC.a. The eccp driver is a wrapper script that cmake
# generates at configure time.
#
# Overrides: EDG_SRC (source tree, default 3rd/edg), EDG_BUILD (output, default build/edg),
# EDG_BASE (base dir, default build/edg-base).
#
# 3rd/edg is take-cheeze/edg-compiler, a fork of edgcpp/compiler that carries nfcxx's front end patches
# (branch nfcxx/cpp17-eval-order: C++17 evaluation order). See docs/notes/eval-order.md.
set -euo pipefail
# The cross target (NFCXX_EDG_TARGET=macos-arm64) builds the prelinker's demangler with IA64_ABI=1 (the NFCXX_DECODE_IA64_ABI
# option of 3rd/edg/util): on a Linux host the default leaves IA64_ABI at 0, which decodes no Itanium names.
cmake_extra=()
[ "${NFCXX_EDG_TARGET:-}" = macos-arm64 ] && cmake_extra=(-DNFCXX_DECODE_IA64_ABI=ON)
root=$(cd "$(dirname "$0")/.." && pwd)
# ccache when it is installed: CMake's compiler launchers (the EDG build is most of a fresh setup).
if command -v ccache >/dev/null; then export CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache; fi
src=${EDG_SRC:-$root/3rd/edg}
out=${EDG_BUILD:-$root/build/edg}
base=${EDG_BASE:-$root/build/edg-base}

if [ ! -f "$src/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

# macOS (Apple Silicon or Intel): EDG's own clang base and CMake preset. Its long double (8 bytes, binary64 on arm64)
# and predefined macros are the macOS ones, so none of the Linux workarounds below apply.
# NFCXX_EDG_TARGET=macos-arm64 (cross path, scripts/setup-cross-macos.sh) takes this branch on a Linux host too: the
# macOS arm64 base and preset, with the front end built by the host's clang. Native Darwin and Linux builds are unchanged.
if [ "$(uname -s)" = Darwin ] || [ "${NFCXX_EDG_TARGET:-}" = macos-arm64 ]; then
  if [ "${NFCXX_EDG_TARGET:-}" = macos-arm64 ]; then
    cfg=macos-arm; preset=macos-arm-clang-release
  else
    case "$(uname -m)" in
      arm64)  cfg=macos-arm;    preset=macos-arm-clang-release ;;
      x86_64) cfg=macos-x86_64; preset=macos-x86-clang-release ;;
      *) echo "setup-edg: unsupported macOS architecture $(uname -m)" >&2; exit 1 ;;
    esac
  fi
  rm -rf "$base"; mkdir -p "$(dirname "$base")"
  cp -r "$src/bases/cmake-native/$cfg/clang" "$base"
  # _POSIX_SOURCE hides Darwin's clock_gettime, CLOCK_MONOTONIC and mkdtemp; _DARWIN_C_SOURCE exposes the full C API, and
  # its blocks declarations (__BLOCKS__, Clang's ^ syntax) are not parsed by EDG, so that macro is undefined.
  sed -i.bak 's|^EDG_DEFAULT_CPP_DEFINES="-D_POSIX_SOURCE"|EDG_DEFAULT_CPP_DEFINES="-D_DARWIN_C_SOURCE -U__BLOCKS__"|' "$base/edg_eccp_config" && rm -f "$base/edg_eccp_config.bak"
  # Let nfcxx pick the C compiler eccp hands the generated C to (NFCXX_CC); the base defaults to clang.
  sed -i.bak 's|^EDG_C_TO_OBJ_COMPILER=clang|EDG_C_TO_OBJ_COMPILER=${NFCXX_CC:-clang}|' "$base/edg_eccp_config" && rm -f "$base/edg_eccp_config.bak"
  # The base builds universal (arm64 + x86_64) objects by default; clang refuses to emit one assembly for several -arch.
  sed -i.bak 's| -arch arm64 -arch x86_64||' "$base/edg_eccp_config" && rm -f "$base/edg_eccp_config.bak"
  # The prelinker reads `nm -og` output. Mach-O values are 16 hex digits, so the nm format is MacOSX64 (-f); without it
  # the default parser rejects the template-info objects ("invalid input format").
  sed -i.bak 's|"nm -og 2>/dev/null" |"nm -og 2>/dev/null" -fMacOSX64 |' "$base/edg_eccp_config" && rm -f "$base/edg_eccp_config.bak"
  if [ "${NFCXX_EDG_TARGET:-}" = macos-arm64 ]; then
    # The cross runtime is C for arm64 Darwin: scripts/cross-macos-cc.sh (clang for the Darwin target, Mach-O objects)
    # compiles it, against the clean-room headers. Its long double is IEEE double (the Apple ABI), which the macOS
    # platform config does not state, so the target values the front end reads are set here, in the generated defines.
    root_cc=$root/scripts/cross-macos-cc.sh
    sed -i.bak "s|^EDG_C_TO_OBJ_COMPILER=.*|EDG_C_TO_OBJ_COMPILER=\${NFCXX_CC:-$root_cc}|" "$base/edg_eccp_config" && rm -f "$base/edg_eccp_config.bak"
    export NFCXX_MACOS_SYSROOT=${NFCXX_MACOS_SYSROOT:-$root/tests/macos-sysroot/include}
  fi
  cd "$src"
  EDG_BASE=$base cmake --preset "$preset" ${cmake_extra[@]+"${cmake_extra[@]}"} -B "$out" >/dev/null
  if [ "${NFCXX_EDG_TARGET:-}" = macos-arm64 ]; then
    cat >> "$out/src/includes/cmake_defines.h" <<'DEFS'

/* macOS arm64: long double is IEEE double (Apple ABI), so the long double and double value sets agree (the front end
   checks the mantissa against the size). Values from IEEE 754. */
#define TARG_DBL_MANT_DIG 53
#define TARG_DBL_MAX_EXP 1024
#define TARG_DBL_MIN_EXP (-1021)
#define TARG_LDBL_MANT_DIG 53
#define TARG_LDBL_MAX_EXP 1024
#define TARG_LDBL_MIN_EXP (-1021)
#define TARG_FLT_MANT_DIG 24
#define TARG_FLT_MAX_EXP 128
#define TARG_FLT_MIN_EXP (-125)
/* The default is set from the host compiler that builds the front end (targ_def.h), which on a Linux host with a recent
   gcc enables __bf16, so the runtime's C99 complex code uses bf16 literals that the macOS arm64 front end rejects. */
#define HOST_COMPILER_SUPPORTS_BFLOAT16 FALSE
DEFS
  fi
  cd "$out"
  ninja bin/cpfe bin/edg_prelink lib/libC.a
  echo "EDG built: $out/bin/eccp"
  exit 0
fi

# EDG_BASE holds edg_eccp_config, predefined macros and headers. Use a copy so the
# submodule stays clean: the stock config passes -Wno-error=return-mismatch, a
# GCC 14+ option that older GCCs reject.
rm -rf "$base"; mkdir -p "$(dirname "$base")"
cp -r "$src/bases/docker/dev-env/gcc" "$base"
# The base dir's include/ is a relative symlink into the submodule, which dangles once
# the directory is copied; point it at the real headers.
ln -sfn "$src/include_c++" "$base/include"
# win64 (--target=win64): EDG's table is Microsoft's and lacks the gcc type macros lib/cstdint needs. With MinGW-w64's gcc
# installed, its predefined macros replace it (scripts/win-predef.sh; docs/notes/freestanding.md, "Windows").
if command -v x86_64-w64-mingw32-gcc >/dev/null; then "$root/scripts/win-predef.sh" "$base/lib_win64/predefined_macros.txt"; fi
if ! echo 'int main(void){return 0;}' | gcc -Werror=return-mismatch -x c -fsyntax-only - 2>/dev/null; then
  sed -i '/-Wno-error=return-mismatch/d' "$base/edg_eccp_config"
fi

# Let nfcxx pick the C compiler eccp hands the generated C to (NFCXX_CC).
sed -i 's|^EDG_C_TO_OBJ_COMPILER=gcc|EDG_C_TO_OBJ_COMPILER=${NFCXX_CC:-gcc}|' "$base/edg_eccp_config"

cd "$src"
EDG_BASE=$base cmake --preset linux-gcc-release ${cmake_extra[@]+"${cmake_extra[@]}"} -B "$out" >/dev/null
# gcc's cmakedef turns on USE_QUADMATH_LIBRARY, but quadmath.h is missing on aarch64 runners. There the host's own
# long double is already the 128-bit IEEE quad that the target uses, so EDG computes with it directly. Approximate
# quadmath (the clang configuration's choice) rejects long double literals that need the full 113-bit mantissa.
if ! echo '#include <quadmath.h>' | g++ -x c++ -fsyntax-only - 2>/dev/null; then
  sed -i 's/^#define USE_QUADMATH_LIBRARY 1$/#define USE_QUADMATH_LIBRARY 0\n#define USE_FLOAT128_FOR_HOST_FP_VALUE 0\n#define USE_LONG_DOUBLE_FOR_HOST_FP_VALUE 1\n#define HOST_FP_VALUE_IS_128BIT 1/' "$out/src/includes/cmake_defines.h"
fi
# The same cmakedef enables __float80 and __float128, which only x86 GCC provides. __float80 is x87-only, so
# turn it off. The front end keeps __float128 (glibc's floatn.h needs it); the C it generates spells it _Float128.
if [ "$(uname -m)" != x86_64 ]; then
  sed -i 's/^#define FLOAT80_ENABLING_POSSIBLE 1$/#define FLOAT80_ENABLING_POSSIBLE 0/' "$out/src/includes/cmake_defines.h"
  sed -i 's/-w -Dva_copy=__va_copy/-w -D__float128=_Float128 -Dva_copy=__va_copy/' "$base/edg_eccp_config"
  # The configured long double is the 128-bit IEEE quad on aarch64 (defines_linux.h). cmake_defines.h still turns on the
  # x87 80-bit format, and EDG refuses a configuration that has both (floating.h), so turn the x87 one off.
  sed -i 's/^#define FP_LONG_DOUBLE_IS_80BIT_EXTENDED 1$/#define FP_LONG_DOUBLE_IS_80BIT_EXTENDED 0\n#define FP_LONG_DOUBLE_IS_BINARY128 1/' "$out/src/includes/cmake_defines.h"
  # The predefined macros are a dump of an x86-64 GCC: they say __x86_64__, which makes libstdc++ use x86 builtins
  # (__builtin_ia32_pause) that EDG does not have. Drop the x86-only entries and take the host's aarch64 ones instead.
  pm=$base/lib/predefined_macros.txt
  x86_names='__FXSR__|__MMX_WITH_SSE__|__MMX__|__SEG_FS|__SEG_GS|__SSE2_MATH__|__SSE2__|__SSE_MATH__|__SSE__|__amd64|__amd64__|__code_model_small__|__k8|__k8__|__x86_64|__x86_64__|__SIZEOF_FLOAT80__|__i386__|__i386'
  { grep '^#' "$pm"
    awk -v x="^($x86_names)\$" '!/^#/ && $3 !~ x' "$pm"
    gcc -dM -E -x c++ /dev/null | grep -E '^#define __(aarch64|ARM_)[A-Za-z0-9_]*( |$)' | sed 's/^#define /gnu no  /'
  } > "$pm.new" && mv "$pm.new" "$pm"
fi
# glibc's aarch64 jmp_buf is 312 bytes (39 longs), but EDG sets the x86-64 size (25 longs) for every Linux target. setjmp then
# writes past the EH stack entry of a try block and into the memory after it, which made throws abort on aarch64.
case "$(uname -m)" in
  aarch64|arm64) sed -i 's/^#define TARG_JMP_BUF_NUM_ELEMENTS 25$/#define TARG_JMP_BUF_NUM_ELEMENTS 39/' "$out/src/includes/cmake_defines.h" ;;
esac
cd "$out"
ninja bin/cpfe bin/edg_prelink lib/libC.a
echo "EDG built: $out/bin/eccp"
