#!/usr/bin/env bash
# CUDA source through the nfcxx driver: the launch rewrite (tools/cuda-rewrite) and the runtime helper
# (lib/cuda/nfcxx_cuda.h). Needs the CUDA runtime headers and libcudart (CUDA_HOME, default /usr/local/cuda) and
# an NVIDIA driver. Skips (exit 0) when they are missing.
#
# Checks: the rewrite matches its golden files; unsupported launch forms are refused (exit 3); mul2.cu compiles
# and links through nfcxx, its device code is built by the driver (tools/cuda-rewrite --device, pathb-ptx-emit,
# ptxas, pathb-ptx-emit --embed), and the program runs the kernels and checks the results. Expected output: "launch: no error"
# and "mul2: 1000 elements, 0 mismatches". (Before the device pipeline, the launch returned an error: the kernel was
# not registered with the runtime.) docs/notes/gpu.md, "CUDA source".
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
[ -x "$root/build/cuda-rewrite" ] || ninja -C "$root/tools/cuda-rewrite" >/dev/null || exit 1
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ]; then
  echo "SKIP: cuda: needs cuda_runtime.h and libcudart (CUDA_HOME)"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
rw() { "$root/build/cuda-rewrite" "$1"; }

# 1. The rewrite matches the goldens.
for c in rewrite/cases mul2 rewrite/template rewrite/syncwarp rewrite/storage rewrite/member_linkage rewrite/device_lambda; do
  if rw "$c.cu" > "$out/$(basename "$c").cpp" && diff -u "$c.expected.cpp" "$out/$(basename "$c").cpp"; then
    echo "rewrite $c: ok"
  else
    echo "rewrite $c: FAIL"; fail=1
  fi
done

# 1b. The device unit of the template case matches its golden (template kernel, helper, no host-only code).
if "$root/build/cuda-rewrite" --device rewrite/template.cu > "$out/template.device.cpp" \
   && diff -u rewrite/template.device.expected.cpp "$out/template.device.cpp"; then
  echo "device unit template: ok"
else
  echo "device unit template: FAIL"; fail=1
fi
# 1c. The device units of a macro named only in a launch's template arguments, and of a launch whose template arguments
# are block-local constants, keep the macro and name the values in the wrapper.
for c in macro_wrapper local_targs launch_macro_body using_namespace define_header_skip static_kernel_enum host_member_drop bf16_class; do
  if "$root/build/cuda-rewrite" --device "rewrite/$c.cu" > "$out/$c.device.cpp" \
     && diff -u "rewrite/$c.device.expected.cpp" "$out/$c.device.cpp"; then
    echo "device unit $c: ok"
  else
    echo "device unit $c: FAIL"; fail=1
  fi
done
# The C++ rewriter (the default driver tool) on the two cases of the launch-argument and device-constant change: the
# Ruby reference refuses them (its launch argument split has the same `->` bug, and it refuses __device__ constants).
cxx="$root/build/cuda-rewrite"
[ -x "$cxx" ] || ninja -C "$root/tools/cuda-rewrite" >/dev/null || exit 1
for c in launch_arrow_args device_const_scalar host_cub_helper bare_dim template_alias_fnptr vec4_alignas nested_fnptr helper_launch addr_taken constexpr_guard default_targs dynshared_operator dep_enumerate braced_range_for extern_instances; do
  if "$cxx" --device "rewrite/$c.cu" > "$out/$c.device.cpp" \
     && diff -u "rewrite/$c.device.expected.cpp" "$out/$c.device.cpp"; then
    echo "device unit $c: ok"
  else
    echo "device unit $c: FAIL"; fail=1
  fi
done

# 1b3. The device pass takes only the branches of the conditionals it evaluates (#if/#elif/#else/#ifndef), so the
# kernels of the untaken branches are not in the unit and not in the kernel list.
if "$root/build/cuda-rewrite" --device --kernels="$out/cond.kernels" rewrite/conditional_kernel.cu > "$out/cond.device.cpp" \
   && diff -u rewrite/conditional_kernel.device.expected.cpp "$out/cond.device.cpp" \
   && [ "$(cat "$out/cond.kernels")" = "$(printf 'fast_kernel\narch_kernel\nifndef_kernel')" ]; then
  echo "device unit conditionals: ok"
else
  echo "device unit conditionals: FAIL"; fail=1
fi

# 1b2. The device unit of __syncwarp (both forms) matches its golden.
if "$root/build/cuda-rewrite" --device rewrite/syncwarp.cu > "$out/syncwarp.device.cpp" \
   && diff -u rewrite/syncwarp.device.expected.cpp "$out/syncwarp.device.cpp"; then
  echo "device unit syncwarp: ok"
else
  echo "device unit syncwarp: FAIL"; fail=1
fi

# 1b2b. A static __shared__ array shadows a dynamic one of the same name in its block only (the device unit keeps the
# static block's uses as the array and rewrites the dynamic kernel's uses to the pointer).
if "$root/build/cuda-rewrite" --device rewrite/shadow_shared.cu > "$out/shadow.device.cpp" \
   && diff -u rewrite/shadow_shared.device.expected.cpp "$out/shadow.device.cpp"; then
  echo "device unit shadow_shared: ok"
else
  echo "device unit shadow_shared: FAIL"; fail=1
fi

# 1b2c. A parameter and a local named like a dynamic array (llama.cpp fattn.cu) are their own declarations in their
# scopes; the device unit takes the C++ branch of a `#ifndef __cplusplus` conditional.
if "$root/build/cuda-rewrite" --device rewrite/shadow_decl.cu > "$out/shadow_decl.device.cpp" \
   && diff -u rewrite/shadow_decl.device.expected.cpp "$out/shadow_decl.device.cpp"; then
  echo "device unit shadow_decl: ok"
else
  echo "device unit shadow_decl: FAIL"; fail=1
fi

# 1b3. A host `const` reference is not a constant: the device unit carries neither its initializer nor its struct type
# (with a FILE * member). A value constant (LIMIT) is still carried.
if "$root/build/cuda-rewrite" --device rewrite/const_host_ref.cu > "$out/const_host_ref.device.cpp" \
   && diff -u rewrite/const_host_ref.device.expected.cpp "$out/const_host_ref.device.cpp"; then
  echo "device unit const_host_ref: ok"
else
  echo "device unit const_host_ref: FAIL"; fail=1
fi

# 1b4. A linkage block (extern "C" { ... }) is split: only the pieces the device unit needs are carried, each inside the
# block's linkage. The host struct with a FILE * member is not carried.
if "$root/build/cuda-rewrite" --device rewrite/linkage_block.cu > "$out/linkage_block.device.cpp" \
   && diff -u rewrite/linkage_block.device.expected.cpp "$out/linkage_block.device.cpp"; then
  echo "device unit linkage_block: ok"
else
  echo "device unit linkage_block: FAIL"; fail=1
fi

# 1c. Included headers are expanded once each: a diamond-shaped include tree (each level includes the next one three
# times) gave 46k lines and took 6 s with the expansion repeated per include; the device unit is 110 lines and
# takes milliseconds. The 10 s limit catches the blow-up again.
if timeout 10 "$root/build/cuda-rewrite" --device rewrite/include/main.cu > "$out/include.device.cpp" \
   && diff -u rewrite/include/main.device.expected.cpp "$out/include.device.cpp"; then
  echo "device unit include tree: ok"
else
  echo "device unit include tree: FAIL"; fail=1
fi

# 2. Unsupported launch forms are refused with exit 3.
for f in rewrite/refuse_*.cu; do
  rc=0; rw "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 3 ]; then echo "refused $(basename "$f"): ok"; else echo "refused $(basename "$f"): FAIL (exit $rc)"; fail=1; fi
done

# 3. mul2.cu through the driver: compile, link, run.
export TMPDIR=$out
# EDG warns about the CUDA headers' pragmas; the log is shown only when the build fails.
if "$root/nfcxx" -c -I"$cuda/include" mul2.cu -o "$out/mul2.o" > "$out/build.log" 2>&1 \
   && "$root/nfcxx" "$out/mul2.o" -L"$cuda/lib64" -lcudart -o "$out/mul2" >> "$out/build.log" 2>&1; then
  run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/mul2") && rc=0 || rc=$?
  if [ "$rc" = 0 ] && [ "$run" = "$(printf 'launch: no error\nmul2: 1000 elements, 0 mismatches')" ]; then
    echo "mul2.cu build and run: ok (device code from the source; results checked)"
  else
    echo "mul2.cu run: FAIL (exit $rc): $run"; fail=1
  fi
else
  cat "$out/build.log"; echo "mul2.cu build: FAIL"; fail=1
fi

# 4. The copy stays out of the source tree, and the object links from another directory. Built from a directory
#    other than the output's, with a relative -o, and linked from a third directory. No .nfcxx directory may be left
#    under the source tree or the build directory, and the copies go to a per-test cache (NFCXX_CU_CACHE).
export NFCXX_CU_CACHE="$out/cache"
mkdir -p "$out/elsewhere/sub" "$out/linkdir"
src=$PWD/mul2.cu
if ( cd "$out/elsewhere" && "$root/nfcxx" -c -I"$cuda/include" "$src" -o sub/rel.o > "$out/rel.log" 2>&1 ) \
   && ( cd "$out/linkdir" && "$root/nfcxx" "$out/elsewhere/sub/rel.o" -L"$cuda/lib64" -lcudart -o "$out/rel" >> "$out/rel.log" 2>&1 ); then
  run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/rel") && rc=0 || rc=$?
  if [ "$rc" = 0 ] && [ "$run" = "$(printf 'launch: no error\nmul2: 1000 elements, 0 mismatches')" ]; then
    echo "relative -o from another directory, linked from a third: ok"
  else
    echo "relative -o run: FAIL (exit $rc): $run"; fail=1
  fi
else
  cat "$out/rel.log"; echo "relative -o build: FAIL"; fail=1
fi
left=$(find "$root/tests/cuda" "$out" -name .nfcxx 2>/dev/null || true)
if [ -z "$left" ]; then echo "no .nfcxx left in the tree: ok"; else echo "no .nfcxx left in the tree: FAIL: $left"; fail=1; fi

# 4b. NFCXX_CACHE keeps the device images: a second compile of the same unit (another object) takes them from the cache,
#     so its time log (NFCXX_TIME_LOG) has no device front end, emitter or ptxas stage, and its program runs. A changed
#     kernel misses.
c4=$out/c4; mkdir -p "$c4"
dev_stages() { cut -f3 "$1" | grep -cE '^(pathb-dump|pathb-ptx-emit --emit|ptxas)' || true; }
for i in 1 2; do
  NFCXX_CACHE=$c4/cache NFCXX_CACHE_LOG=$c4/cache.log NFCXX_TIME_LOG=$c4/time$i.log \
    "$root/nfcxx" -c -I"$cuda/include" mul2.cu -o "$c4/m$i.o" > "$c4/build.log" 2>&1 || { cat "$c4/build.log"; echo "cache build $i: FAIL"; fail=1; }
done
sed 's/a\[i\] \* 2;/a[i] * 2 + 0 * n;/' mul2.cu > "$c4/mul2b.cu"
NFCXX_CACHE=$c4/cache NFCXX_CACHE_LOG=$c4/cache.log "$root/nfcxx" -c -I"$cuda/include" "$c4/mul2b.cu" -o "$c4/m3.o" > "$c4/build.log" 2>&1 \
  || { cat "$c4/build.log"; echo "cache build 3: FAIL"; fail=1; }
states=$(grep -E '^(hit|miss)$' "$c4/cache.log" | tr '\n' ' ')
if [ "$states" = "miss hit miss " ] && [ "$(dev_stages "$c4/time1.log")" = 3 ] && [ "$(dev_stages "$c4/time2.log")" = 0 ] \
   && cut -f2 "$c4/time2.log" | grep -qx eccp && "$root/nfcxx" "$c4/m2.o" -L"$cuda/lib64" -lcudart -o "$c4/m2" >> "$c4/build.log" 2>&1 \
   && [ "$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$c4/m2")" = "$(printf 'launch: no error\nmul2: 1000 elements, 0 mismatches')" ]; then
  echo "device image cache (miss, hit, changed kernel misses) and time log: ok"
else
  echo "device image cache: FAIL ($states)"; cat "$c4/time1.log" "$c4/time2.log"; fail=1
fi

# 4. The launch path (llama.cpp features): tests/cuda/launch/run.sh.
"$root/tests/cuda/launch/run.sh" || fail=1
# 5. Kernels split into several device modules (the driver's grouping; tests/cuda/groups/run.sh).
"$root/tests/cuda/groups/run.sh" || fail=1
# 6. Instances declared extern in a header are compiled only by the unit that defines them (tests/cuda/extern_inst/run.sh).
"$root/tests/cuda/extern_inst/run.sh" || fail=1

exit $fail
