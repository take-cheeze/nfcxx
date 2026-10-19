#!/usr/bin/env bash
# Device printf through the driver (tools/pathb-ptx-emit lowers the call to vprintf; the runtime prints the lines
# when the kernel completes). Checks the exact output, a mutant (a changed format must change the output), and that a
# printf whose format is not a string constant is refused with exit 3. Needs the CUDA toolkit and an NVIDIA GPU; skips
# (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: printf: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out
want=$'thread 0 value 1.50\nthread 1 value 1.50\nthread 2 value 1.50\nsync: no error'

run_src() {  # run_src FILE.cu NAME -> prints the program's output (empty on failure)
  "$root/nfcxx" -c -I"$cuda/include" "$1" -o "$out/$2.o" > "$out/$2.log" 2>&1 \
    && "$root/nfcxx" "$out/$2.o" -L"$cuda/lib64" -lcudart -o "$out/$2" >> "$out/$2.log" 2>&1 \
    && LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$2"
}

got=$(run_src printf.cu printf) || got=""
if [ "$got" = "$want" ]; then echo "printf: exact output (3 lines and the sync line)"; else echo "FAIL printf: output differs"; echo "$got" | head -5; fail=1; fi

sed 's/value %.2f/value %.3f/' printf.cu > "$out/mut.cu"
gotm=$(run_src "$out/mut.cu" mut) || gotm=""
if [ -n "$gotm" ] && [ "$gotm" != "$want" ]; then echo "mutant printf: format change caught"; else echo "FAIL mutant printf: not caught"; fail=1; fi

rc=0
"$root/nfcxx" -c -I"$cuda/include" refuse_fmt.cu -o "$out/refuse.o" > "$out/refuse.log" 2>&1 || rc=$?
if [ "$rc" = 3 ] && grep -q "printf format must be a string constant" "$out/refuse.log"; then
  echo "refused printf with a non-constant format: ok"
else
  echo "FAIL refuse printf (exit $rc)"; grep -m2 "refused\|error" "$out/refuse.log" | cut -c1-160; fail=1
fi
exit $fail
