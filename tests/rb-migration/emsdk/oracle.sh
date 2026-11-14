#!/usr/bin/env bash
# Install the Emscripten SDK (emsdk) into build/emsdk, at a pinned release, for the browser build of the Path B front end
# (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh; docs/notes/pathb-wasm-frontend.md). Then, in the shell that builds:
#   source build/emsdk/emsdk_env.sh
# Does nothing if the pinned release is installed already.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=${EMSDK_VERSION:-6.0.13}
dir=$root/build/emsdk
if [ ! -x "$dir/emsdk" ]; then
  mkdir -p "$root/build"
  git clone -q --depth 1 https://github.com/emscripten-core/emsdk.git "$dir"
fi
if [ "$(cat "$dir/.nfcxx-version" 2>/dev/null)" != "$version" ]; then
  "$dir/emsdk" install "$version"
  "$dir/emsdk" activate "$version"
  echo "$version" > "$dir/.nfcxx-version"
fi
echo "setup-emsdk: emsdk $version in $dir (source $dir/emsdk_env.sh)"
