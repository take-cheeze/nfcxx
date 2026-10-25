#!/usr/bin/env bash
# The mruby interpreter of scripts/mrb, built with Emscripten (scripts/mruby-wasm-config.rb), for the browser:
# build/mruby-wasm/out/wasm/bin/mruby.js and mruby.wasm. Uses the pinned mruby source of scripts/setup-mruby.sh and
# Emscripten on PATH (scripts/setup-emsdk.sh, then source build/emsdk/emsdk_env.sh).
#   FORCE=1   build again
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$root/build/mruby-wasm
out=$work/out/wasm/bin/mruby.js
[ -z "${FORCE:-}" ] && [ -f "$out" ] && exit 0
command -v emcc >/dev/null || { echo "setup-mruby-wasm: emcc is not on PATH (scripts/setup-emsdk.sh)" >&2; exit 1; }
FORCE= "$root/scripts/setup-mruby.sh"     # the pinned source (and the host interpreter)
src=$root/build/mruby-tool/src
if command -v rake >/dev/null; then rake=(rake); else rake=(ruby -rrake -e 'Rake.application.run(ARGV)' --); fi
mkdir -p "$work"
cp "$root/scripts/mruby-wasm-config.rb" "$work/build_config.rb"
(cd "$src" && MRUBY_CONFIG=$work/build_config.rb MRUBY_BUILD_DIR=$work/out "${rake[@]}" -j"$(nproc)" all) \
  > "$work/build.log" 2>&1 \
  || { tail -20 "$work/build.log" >&2; echo "setup-mruby-wasm: build failed ($work/build.log)" >&2; exit 1; }
[ -f "$out" ] || { echo "setup-mruby-wasm: $out was not built" >&2; exit 1; }
echo "setup-mruby-wasm: $out ($(wc -c < "${out%.js}.wasm") bytes of wasm)"
