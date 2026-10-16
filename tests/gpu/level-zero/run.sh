#!/usr/bin/env bash
# Level Zero check (lib/sycl/include/sycl/rt_level_zero.hpp, docs/notes/sycl-vulkan.md): the vecAdd kernel of tests/gpu/device,
# lowered from the Path B IR to SPIR-V by scripts/pathb-spirv-kernel-emit.rb, assembled by spirv-as, and run on an Intel GPU
# through Level Zero (launch.c) over 50000 elements, with the arrays in shared USM. Checks: the assembly matches its golden
# (tests/gpu/spirv/vecadd.spvasm), a mutant (OpFAdd -> OpFSub) must fail the run.
# Needs the Level Zero headers (ze_api.h), the loader (libze_loader.so.1), spirv-as, spirv-val (SPIRV_TOOLS_BIN or PATH) and
# an Intel GPU with the Level Zero driver. Skips (exit 0) when one is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
tools=${SPIRV_TOOLS_BIN:-}
if [ -n "$tools" ]; then export PATH="$tools:$PATH"; fi
loader=""
for p in /usr/lib/x86_64-linux-gnu/libze_loader.so.1 /usr/lib/libze_loader.so.1 /usr/lib64/libze_loader.so.1; do
  [ -e "$p" ] && loader=$p && break
done
if ! command -v spirv-as >/dev/null || ! command -v spirv-val >/dev/null || [ ! -f /usr/include/level_zero/ze_api.h ] \
   || [ -z "$loader" ]; then
  echo "SKIP: gpu level-zero: needs spirv-as, spirv-val, the Level Zero headers (ze_api.h) and libze_loader.so.1"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 1. The emitted assembly matches its golden (the same module as the OpenCL check).
"$root/scripts/mrb" "$root/scripts/pathb-spirv-kernel-emit.rb" ../device/vecadd.ir > "$out/vecadd.spvasm"
if diff -u ../spirv/vecadd.spvasm "$out/vecadd.spvasm"; then echo "asm vecadd: ok"; else echo "asm vecadd: FAIL"; fail=1; fi

# 2. It assembles and validates (SPIR-V 1.1, as the OpenCL check; the Level Zero driver takes it).
spirv-as --target-env spv1.1 "$out/vecadd.spvasm" -o "$out/vecadd.spv"
if spirv-val --target-env spv1.1 "$out/vecadd.spv"; then echo "validate vecadd: ok"; else echo "validate vecadd: FAIL"; fail=1; fi

# 3. The launcher runs it on the GPU; every element and the guard region are checked.
gcc -O2 -Wall -o "$out/launch" launch.c -l:libze_loader.so.1
set +e
run=$("$out/launch" "$out/vecadd.spv" _Z6vecAddPfS_S_i 2>&1); rc=$?
set -e
if [ $rc = 2 ] && grep -q "no Level Zero GPU" <<< "$run"; then
  echo "SKIP: gpu level-zero: no Level Zero GPU device"; exit 0
fi
if [ $rc = 2 ] && grep -q "no shared USM with atomic" <<< "$run"; then
  echo "$run"; echo "SKIP: gpu level-zero: the device has no shared USM with atomics"; exit 0
fi
echo "$run"
if [ $rc = 0 ]; then echo "run vecadd: ok"; else echo "run vecadd: FAIL"; fail=1; fi

# 4. A mutant (add -> sub) must fail the same run.
sed 's/OpFAdd/OpFSub/' "$out/vecadd.spvasm" > "$out/mut.spvasm"
spirv-as --target-env spv1.1 "$out/mut.spvasm" -o "$out/mut.spv"
if "$out/launch" "$out/mut.spv" _Z6vecAddPfS_S_i >/dev/null 2>&1; then
  echo "mutant vecadd: FAIL (not caught)"; fail=1
else
  echo "mutant vecadd: caught"
fi

exit $fail
