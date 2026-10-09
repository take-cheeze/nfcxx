#!/usr/bin/env bash
# Build the EDG C++ front end (Apache 2.0, submodule at 3rd/edg) out of tree into
# build/edg. Builds only the host tools nfcxx needs: cpfe (front end), edg_prelink
# (template instantiation), libC.a. The eccp driver is a wrapper script that cmake
# generates at configure time.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/3rd/edg
out=$root/build/edg

if [ ! -f "$src/CMakeLists.txt" ]; then
  git -C "$root" submodule update --init --depth 1 3rd/edg
fi

# EDG_BASE holds edg_eccp_config, predefined macros and headers. Use a copy so the
# submodule stays clean: the stock config passes -Wno-error=return-mismatch, a
# GCC 14+ option that older GCCs reject.
base=$root/build/edg-base
rm -rf "$base"; mkdir -p "$root/build"
cp -r "$src/bases/docker/dev-env/gcc" "$base"
if ! echo 'int main(void){return 0;}' | gcc -Werror=return-mismatch -x c -fsyntax-only - 2>/dev/null; then
  sed -i '/-Wno-error=return-mismatch/d' "$base/edg_eccp_config"
fi

cd "$src"
EDG_BASE=$base cmake --preset linux-gcc-release -B "$out" >/dev/null
cd "$out"
ninja bin/cpfe bin/edg_prelink lib/libC.a
echo "EDG built: $out/bin/eccp"
