#!/usr/bin/env bash
# The SSA structurizer (scripts/pathb-ssa-structurize.rb, docs/notes/pathb-structurize.md): the golden of tests/gpu/device
# (switch.ir) convert, the output parses as IR (the inliner reads it), and the SYCL vecadd program through the whole chain
# (NFCXX_CFG=structurize) validates as SPIR-V. Needs ruby, spirv-val and the nfcxx build for the last step (skipped without them).
set -uo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
ruby "$root/scripts/pathb-ssa.rb" "$root/tests/gpu/device/switch.ir" > "$out/s.ssa" && \
  ruby "$root/scripts/pathb-ssa-structurize.rb" "$out/s.ssa" > "$out/s.sir" && echo "structurize switch: ok" || { echo "structurize switch: FAIL"; fail=1; }
if "${RUBY:-ruby}" "$root/scripts/pathb-ir-opt.rb" --inline "$out/s.sir" > /dev/null 2>&1; then echo "parse switch: ok"; else echo "parse switch: FAIL"; fail=1; fi
if [ -x "$root/build/edg/bin/eccp" ] && command -v spirv-val >/dev/null; then
  if NFCXX_CFG=structurize "$root/scripts/sycl-build.sh" --backend=vulkan "$root/tests/sycl/vecadd.cpp" -o "$out/vk" > "$out/build.log" 2>&1 && \
     (cd "$out" && ./vk | grep -q "^vecadd ok"); then echo "vecadd through the structurizer: ok (runs where a Vulkan device is present)"
  else echo "vecadd through the structurizer: FAIL (see $out/build.log)"; fail=1; fi
else echo "vecadd through the structurizer: SKIP (needs the nfcxx build and spirv-val)"; fi
exit $fail
