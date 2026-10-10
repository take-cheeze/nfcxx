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
root=$(cd "$(dirname "$0")/.." && pwd)
src=${EDG_SRC:-$root/3rd/edg}
out=${EDG_BUILD:-$root/build/edg}
base=${EDG_BASE:-$root/build/edg-base}

if [ ! -f "$src/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

# EDG_BASE holds edg_eccp_config, predefined macros and headers. Use a copy so the
# submodule stays clean: the stock config passes -Wno-error=return-mismatch, a
# GCC 14+ option that older GCCs reject.
rm -rf "$base"; mkdir -p "$(dirname "$base")"
cp -r "$src/bases/docker/dev-env/gcc" "$base"
# The base dir's include/ is a relative symlink into the submodule, which dangles once
# the directory is copied; point it at the real headers.
ln -sfn "$src/include_c++" "$base/include"
if ! echo 'int main(void){return 0;}' | gcc -Werror=return-mismatch -x c -fsyntax-only - 2>/dev/null; then
  sed -i '/-Wno-error=return-mismatch/d' "$base/edg_eccp_config"
fi

# Let nfcxx pick the C compiler eccp hands the generated C to (NFCXX_CC).
sed -i 's|^EDG_C_TO_OBJ_COMPILER=gcc|EDG_C_TO_OBJ_COMPILER=${NFCXX_CC:-gcc}|' "$base/edg_eccp_config"

cd "$src"
EDG_BASE=$base cmake --preset linux-gcc-release -B "$out" >/dev/null
cd "$out"
ninja bin/cpfe bin/edg_prelink lib/libC.a
echo "EDG built: $out/bin/eccp"
