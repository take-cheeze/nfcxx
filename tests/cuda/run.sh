#!/usr/bin/env bash
# CUDA source through the nfcxx driver: the launch rewrite (scripts/cuda-rewrite.rb) and the runtime helper
# (lib/cuda/nfcxx_cuda.h). Needs the CUDA runtime headers and libcudart (CUDA_HOME, default /usr/local/cuda) and
# an NVIDIA driver. Skips (exit 0) when they are missing.
#
# Checks: the rewrite matches its golden files; unsupported launch forms are refused (exit 3); mul2.cu compiles
# and links through nfcxx and runs. Device code is not built yet, so the kernel is not registered with the runtime
# and the launch returns an error (cudaErrorInvalidResourceHandle here); the test asserts that the call reached the
# runtime and that the program did not crash. Once device code is linked, the expected result changes to
# "mul2: 0 mismatches" (see docs/notes/gpu.md).
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
for c in rewrite/cases mul2; do
  if rw "$c.cu" > "$out/$(basename "$c").cpp" && diff -u "$c.expected.cpp" "$out/$(basename "$c").cpp"; then
    echo "rewrite $c: ok"
  else
    echo "rewrite $c: FAIL"; fail=1
  fi
done

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
  if [ "$rc" = 0 ] && [ "$run" = "launch: invalid resource handle" ]; then
    echo "mul2.cu build and run: ok (launch reaches the runtime; no device code yet)"
  else
    echo "mul2.cu run: FAIL (exit $rc): $run"; fail=1
  fi
else
  cat "$out/build.log"; echo "mul2.cu build: FAIL"; fail=1
fi

exit $fail
