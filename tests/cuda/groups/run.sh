#!/usr/bin/env bash
# Kernels split into several device modules through the nfcxx driver (pathb-ptx-emit --groups-dir; one cubin per module;
# the runtime loads each kernel from its module). groups.cu has four kernels, three of them with a 256-byte table.
# Checks: the default budget gives one module and the right results; a constant budget of 300 bytes and a line budget of
# 80 each split the file into several modules (counted from the images in the object) with the same results; the
# GROUPS_MUTANT build (one device value changed) must report the mismatch; a kernel over the budget alone is refused (exit 3).
# Skips (exit 0) when CUDA_HOME, the runtime or a GPU is missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ]; then
  echo "SKIP: groups: needs cuda_runtime.h and libcudart (CUDA_HOME)"; exit 0
fi
if ! nvidia-smi -L >/dev/null 2>&1; then echo "SKIP: groups: needs a GPU (nvidia-smi)"; exit 0; fi

fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out

# build NAME [VAR=VALUE...]: compiles groups.cu with the environment given (and $DEFS, extra compile options) and links it;
# the log is kept in $out/NAME.log
build() {
  local name=$1; shift
  env "$@" "$root/nfcxx" -c -I"$cuda/include" ${DEFS:-} groups.cu -o "$out/$name.o" > "$out/$name.log" 2>&1 \
    && "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart -o "$out/$name" >> "$out/$name.log" 2>&1
}
images() { nm "$out/$1.o" | grep -c '__nfcxx_image_' || true; }
run() { LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$1" 2>&1; }

want="groups a: 0 mismatches
groups b: 0 mismatches
groups c: 0 mismatches
groups d: 0 mismatches
groups: no error, 0 mismatches"

# 1. The default budget: one module.
if build default; then
  got=$(run default) && rc=0 || rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [ "$(images default)" = 1 ]; then
    echo "groups default budget: one module, results ok"
  else
    echo "groups default budget: FAIL (exit $rc, images $(images default)): $got"; fail=1
  fi
else
  cat "$out/default.log"; echo "groups default budget build: FAIL"; fail=1
fi

# 2. A constant budget of 300 bytes: each 256-byte table's kernel gets its own module.
if build cbytes NFCXX_CUDA_MAX_CONST_BYTES=300; then
  got=$(run cbytes) && rc=0 || rc=$?
  n=$(images cbytes)
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [ "$n" -ge 2 ]; then
    echo "groups constant budget: $n modules, results ok"
  else
    echo "groups constant budget: FAIL (exit $rc, modules $n): $got"; fail=1
  fi
else
  cat "$out/cbytes.log"; echo "groups constant budget build: FAIL"; fail=1
fi

# 3. A PTX-line budget of 80: the functions split the kernels into modules (mix() is a .func in each).
if build lines NFCXX_CUDA_MAX_PTX_LINES=80; then
  got=$(run lines) && rc=0 || rc=$?
  n=$(images lines)
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [ "$n" -ge 2 ]; then
    echo "groups line budget: $n modules, results ok"
  else
    echo "groups line budget: FAIL (exit $rc, modules $n): $got"; fail=1
  fi
else
  cat "$out/lines.log"; echo "groups line budget build: FAIL"; fail=1
fi

# 4. Mutant: one device value of kernel b is wrong, in a split build. The run must report it and exit non-zero.
if DEFS=-DGROUPS_MUTANT build mutant NFCXX_CUDA_MAX_CONST_BYTES=300; then
  got=$(run mutant) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && echo "$got" | grep -q "^groups b: 1 mismatches$" && echo "$got" | grep -q "^groups: FAILED, 1 mismatches$"; then
    echo "groups mutant: caught ($(echo "$got" | tail -1))"
  else
    echo "groups mutant: FAIL (not caught, exit $rc): $got"; fail=1
  fi
else
  cat "$out/mutant.log"; echo "groups mutant build: FAIL"; fail=1
fi

# 5. A kernel whose closure is over the budget alone is refused by the emitter (exit 3 from the driver's compile).
rc=0; build refuse NFCXX_CUDA_MAX_PTX_LINES=10 || rc=$?
if [ "$rc" = 3 ] && grep -q "alone needs" "$out/refuse.log"; then
  echo "groups over-budget kernel: refused (exit 3)"
else
  echo "groups over-budget kernel: FAIL (exit $rc): $(tail -1 "$out/refuse.log")"; fail=1
fi

exit $fail
