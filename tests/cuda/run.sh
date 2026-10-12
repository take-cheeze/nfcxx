#!/usr/bin/env bash
# CUDA source through the nfcxx driver: the launch rewrite (scripts/cuda-rewrite.rb) and the runtime helper
# (lib/cuda/nfcxx_cuda.h). Needs the CUDA runtime headers and libcudart (CUDA_HOME, default /usr/local/cuda) and
# an NVIDIA driver. Skips (exit 0) when they are missing.
#
# Checks: the rewrite matches its golden files; unsupported launch forms are refused (exit 3); mul2.cu compiles
# and links through nfcxx, its device code is built by the driver (scripts/cuda-rewrite.rb --device, pathb-ptx-emit,
# ptxas, cuda-embed), and the program runs the kernels and checks the results. Expected output: "launch: no error"
# and "mul2: 1000 elements, 0 mismatches". (Before the device pipeline, the launch returned an error: the kernel was
# not registered with the runtime.) docs/notes/gpu.md, "CUDA source".
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ]; then
  echo "SKIP: cuda: needs cuda_runtime.h and libcudart (CUDA_HOME)"; exit 0
fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
rw() { "$root/scripts/mrb" "$root/scripts/cuda-rewrite.rb" "$1"; }

# 1. The rewrite matches the goldens.
for c in rewrite/cases mul2 rewrite/template; do
  if rw "$c.cu" > "$out/$(basename "$c").cpp" && diff -u "$c.expected.cpp" "$out/$(basename "$c").cpp"; then
    echo "rewrite $c: ok"
  else
    echo "rewrite $c: FAIL"; fail=1
  fi
done

# 1b. The device unit of the template case matches its golden (template kernel, helper, no host-only code).
if "$root/scripts/mrb" "$root/scripts/cuda-rewrite.rb" --device rewrite/template.cu > "$out/template.device.cpp" \
   && diff -u rewrite/template.device.expected.cpp "$out/template.device.cpp"; then
  echo "device unit template: ok"
else
  echo "device unit template: FAIL"; fail=1
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

exit $fail
