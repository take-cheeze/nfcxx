#!/usr/bin/env bash
# llama.cpp's Vulkan backend through the nfcxx driver, on the GPU: tests/llamacpp/vulkan/build.sh builds ggml with
# ggml-vulkan (the host code by nfcxx, the shaders by glslc) and links llama.cpp's test-backend-ops, which runs each op
# on Vulkan0 and compares it with the CPU backend. Each op runs in its own process. Every op test-backend-ops lists must
# pass every case it has, except the ops in KNOWN (docs/notes/llamacpp.md, "Vulkan backend"); one of those that passes
# fails the test, so the record gets updated.
# The build is about 180 objects (ggml-vulkan.cpp and the 155 generated shader sources among them); objects are kept in
# OUT, so a second run only links.
# Env: OUT (build directory, default build/llvk), VK_DEVICE (default Vulkan0), and build.sh's LLAMA, JOBS.
# Skips (exit 0, with the reason) without the llama.cpp clone, vulkan.hpp, glslc or a Vulkan GPU.
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${OUT:-$root/build/llvk}
dev=${VK_DEVICE:-Vulkan0}
command -v vulkaninfo > /dev/null && vulkaninfo --summary 2>/dev/null | grep -q 'PHYSICAL_DEVICE_TYPE_\(INTEGRATED\|DISCRETE\)_GPU' ||
  { echo "SKIP: llamacpp vulkan: no Vulkan GPU"; exit 0; }
log=$("$root/tests/llamacpp/vulkan/build.sh" "$out") || { echo "$log" | tail -5; exit 1; }
case $log in *SKIP:*) echo "$log"; exit 0 ;; esac
prog=$out/test-backend-ops

# op | why it fails now (see docs/notes/llamacpp.md)
KNOWN=""

fail=0
mkdir -p "$out/ops"
for op in $("$prog" --list-ops 2>/dev/null | awk '/^  [A-Z0-9_]+$/ {print $1}'); do
  l=$out/ops/$op.log
  timeout 1800 "$prog" test -b "$dev" -o "^$op\$" > "$l" 2>&1
  res=$(grep -oE '[0-9]+/[0-9]+ tests passed' "$l" | head -1 | cut -d' ' -f1)
  why=$(echo "$KNOWN" | grep "^$op|" | cut -d'|' -f2)
  if [ -n "$res" ] && [ "${res%/*}" = "${res#*/}" ]; then
    if [ -n "$why" ]; then echo "NOW PASSES $op $res: take it out of KNOWN"; fail=1; else echo "ok   $op $res"; fi
  elif [ -n "$why" ]; then
    echo "known $op ${res:--}: $why"
  else
    echo "FAIL $op ${res:--} $(grep -m1 -E 'FAIL|error|Abort' "$l" | cut -c1-160)"; fail=1
  fi
done
exit $fail
