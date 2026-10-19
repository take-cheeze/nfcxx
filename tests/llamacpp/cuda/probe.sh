#!/usr/bin/env bash
# Per-file probe of llama.cpp's CUDA backend through the nfcxx driver: every ggml-cuda .cu (the template
# instances included) is compiled with nfcxx -c, the way the driver compiles a .cu input (host copy, device unit,
# embedded cubin). Writes one log per file and a table (file, status, stage, first error) to OUT.
# Usage: tests/llamacpp/cuda/probe.sh [OUT_DIR]     (default: build/probe/llcu)
# Env: LLAMA (clone, default build/targets/llama.cpp), CUDA_HOME (default /usr/local/cuda), JOBS (default 8),
# FILES (a list of relative .cu paths under ggml-cuda, one per line, to probe instead of all of them).
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
llama=${LLAMA:-$root/build/targets/llama.cpp}
cuda=${CUDA_HOME:-/usr/local/cuda}
out=${1:-$root/build/probe/llcu}
src=$llama/ggml/src/ggml-cuda
if [ ! -d "$src" ] || [ ! -f "$cuda/include/cuda_runtime.h" ]; then
  echo "SKIP: llama.cpp clone ($src) or CUDA headers ($cuda) missing"; exit 0
fi
mkdir -p "$out/logs"
export root out src cuda llama
export NFCXX_BACKEND=gcc
list=${FILES:-$(cd "$src" && find . -name '*.cu' | sort)}
echo "$list" | xargs -P "${JOBS:-8}" -I{} bash -c '
  f="{}"; n=$(echo "$f" | sed "s|^\./||; s|/|__|g")
  d=$(mktemp -d "$root/build/probe/tmp.XXXX")
  TMPDIR=$d timeout 2400 "$root/nfcxx" -c -std=c++17 -DGGML_USE_CUDA -I"$root/lib/cuda/host" -I"$cuda/include" -I"$cuda/include/cccl" \
    -I"$llama/ggml/include" -I"$llama/ggml/src" -I"$llama/ggml/src/ggml-cuda" "$src/$f" -o "$d/o.o" \
    > "$out/logs/$n.log" 2>&1
  echo $? > "$out/logs/$n.rc"; rm -rf "$d"'
{
  printf '%-48s %-6s %-12s %s\n' file status stage first-error
  echo "$list" | while read -r f; do
    n=$(echo "$f" | sed 's|^\./||; s|/|__|g'); rc=$(cat "$out/logs/$n.rc" 2>/dev/null || echo "?")
    log="$out/logs/$n.log"
    if [ "$rc" = 0 ]; then st=ok; stage=-; err=-
    else
      st=FAIL
      err=$(grep -m1 -E ' error|refused:|undefined reference|catastrophic|cannot open' "$log" | sed 's/^ *//' | cut -c1-150)
      [ -n "$err" ] || err=$(head -1 "$log" | cut -c1-150)
      case "$err" in
        *refused:*) stage=emitter ;;
        *"undefined reference"*) stage=link ;;
        *"cannot open"*) stage=include ;;
        *) stage=front-end ;;
      esac
    fi
    printf '%-48s %-6s %-12s %s\n' "$f" "$st" "$stage" "$err"
  done
} > "$out/table.txt"
echo "wrote $out/table.txt: $(grep -c ' ok ' "$out/table.txt") ok of $(echo "$list" | wc -l)"
