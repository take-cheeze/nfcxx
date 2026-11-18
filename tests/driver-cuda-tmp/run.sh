#!/bin/bash
# The .cu route leaves no temporary directory behind: the device-records directory (cudatmp) is removed on every exit,
# after a compile to an object, after a link with a main, and after a link that fails (no main). It needs a CUDA toolkit
# (CUDA_HOME with bin/ptxas and include/cuda_runtime.h, e.g. scripts/fetch-cuda-libs.sh); without one it is skipped.
#   CUDA_HOME=/path/to/toolkit bash tests/driver-cuda-tmp/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
if [ -z "${CUDA_HOME:-}" ] || [ ! -x "$CUDA_HOME/bin/ptxas" ] || [ ! -f "$CUDA_HOME/include/cuda_runtime.h" ]; then
  echo "skip: no CUDA toolkit (CUDA_HOME with bin/ptxas and include/cuda_runtime.h)"; exit 0
fi
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
cp "$repo/tests/nfcxx-cuda-device/fixtures/mul2.cu" .
printf 'int main() { return 0; }\n' > main.cpp
tdir="$work/tmp"; mkdir "$tdir"
export TMPDIR="$tdir"
left() { ls -A "$tdir" | wc -l; }

"$repo/nfcxx" -c mul2.cu -o mul2.o >/dev/null 2>&1; st=$?
if [ $st = 0 ] && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL .cu compile (status $st, left $(left))"; fi

"$repo/nfcxx" -o prog mul2.o main.cpp -L"$CUDA_HOME/lib64" -lcudart >/dev/null 2>&1; st=$?
if [ $st = 0 ] && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL .cu link with main (status $st, left $(left))"; fi

"$repo/nfcxx" -o prog2 mul2.o -L"$CUDA_HOME/lib64" -lcudart >/dev/null 2>&1; st=$?
if [ $st != 0 ] && [ "$(left)" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL failing .cu link leaves a directory (status $st, left $(left))"; fi

echo "driver-cuda-tmp: $pass passed, $fail failed"
[ $fail = 0 ]
