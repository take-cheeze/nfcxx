#!/usr/bin/env bash
# SASS decode check: the cubin ptxas builds from the emitter's mul2 kernel (tests/gpu/mul2.ir) is decoded by the
# reference decoder of nvdisasm-re (src/sass/decode/pydecode.py), which reads the committed machine descriptions and
# needs no CUDA tools. Every instruction word must decode (undecodable words print as "<illegal: ...>"), and the
# kernel must end in EXIT. Needs ptxas (CUDA_HOME) and a checkout of https://github.com/edmcman/nvdisasm-re
# (NFCXX_SASS_RE). Skips (exit 0) when either is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(cd ../.. && pwd)
[ -x "$root/build/pathb-ptx-emit" ] || ninja -C "$root/tools/pathb-ptx-emit" >/dev/null || exit 1
arch=${GPU_ARCH:-sm_75}
cuda=${CUDA_HOME:-/usr/local/cuda}
re=${NFCXX_SASS_RE:-}

ptxas=$cuda/bin/ptxas
if [ ! -x "$ptxas" ] || [ -z "$re" ] || [ ! -f "$re/src/sass/decode/pydecode.py" ]; then
  echo "SKIP: sass: needs ptxas (CUDA_HOME) and an nvdisasm-re checkout (NFCXX_SASS_RE)"; exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
"$root/build/pathb-ptx-emit" --emit mul2.ir > "$out/mul2.ptx"
"$ptxas" -arch="$arch" "$out/mul2.ptx" -o "$out/mul2.cubin"
PYTHONPATH="$re/src" python3 -m sass.decode.pydecode "$out/mul2.cubin" > "$out/mul2.sass"

fail=0
if grep -q '<illegal:' "$out/mul2.sass"; then
  echo "sass mul2 ($arch): FAIL: undecodable words"; grep '<illegal:' "$out/mul2.sass" | head -5; fail=1
fi
if ! grep -q 'EXIT' "$out/mul2.sass"; then
  echo "sass mul2 ($arch): FAIL: no EXIT in the decoded kernel"; fail=1
fi
[ "$fail" = 0 ] && echo "sass mul2 ($arch): $(grep -c '/\*[0-9a-f]\{4\}\*/' "$out/mul2.sass") instructions decoded, ok"
exit "$fail"
