#!/usr/bin/env bash
# The device unit's keep rules (llama.cpp's mmq and ggml-cuda units): a macro from an -I header reached through an
# angle include is carried (QK_K); a host struct with a std::string member, and a host function whose head returns an
# enum, are not; a typedef, an enum and an anonymous union are. The macro case also runs on the GPU through the driver.
# File-scope enums: an anonymous and a named one used by a kernel are carried and run on the GPU; a host-only one is not.
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU for the run; the golden check
# needs only the rewriter (mruby).
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# 1. The device unit of keep.cu matches its golden.
if "$root/scripts/mrb" "$root/scripts/cuda-rewrite.rb" --device --kernels="$out/k" keep.cu > "$out/keep.cpp" \
   && diff -u keep.device.expected.cpp "$out/keep.cpp"; then
  echo "device unit keep rules: ok"
else
  echo "device unit keep rules: FAIL"; fail=1
fi

# 2. QK_K from an -I header reaches the device unit (checked by the golden of the macro case below), and the program
# runs on the GPU with the right value.
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP macro run: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"
else
  export TMPDIR=$out NFCXX_BACKEND=gcc   # the CUDA runtime headers do not compile on the qbe backend
  if "$root/nfcxx" -c -I"$root/tests/cuda/devunit/inc" -I"$cuda/include" src/macro.cu -o "$out/macro.o" > "$out/macro.log" 2>&1 \
     && "$root/nfcxx" "$out/macro.o" -L"$cuda/lib64" -lcudart -o "$out/macro" >> "$out/macro.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/macro") && [[ "$run" == "macro: 0 mismatches" ]]; then
    echo "macro run: $run"
  else
    echo "macro run: FAIL"; grep -v "pragma\|NV_SILENCE\|^ *\^\|warning\|^ *$" "$out/macro.log" | head -5; fail=1
  fi
fi

# 3. File-scope enums used by device code: an anonymous one and a named one are carried; a host-only enum is not.
if ! "$root/scripts/mrb" "$root/scripts/cuda-rewrite.rb" --device --kernels="$out/enumk" src/enum.cu > "$out/enum.dev.cpp" 2>/dev/null; then
  echo "enum device unit: FAIL (the rewriter refused it)"; fail=1
elif grep -q "HO_ONE" "$out/enum.dev.cpp"; then
  echo "enum device unit: FAIL (a host-only enumerator reached the device unit)"; fail=1
elif [ "$(grep -c "ANON_SCALE = 3\|NAMED_BASE = 100" "$out/enum.dev.cpp")" != 2 ]; then
  echo "enum device unit: FAIL (a used enum is missing from the device unit)"; fail=1
else
  echo "enum device unit: ok (anonymous and named enums carried; host-only enum dropped)"
fi
if [ -f "$cuda/include/cuda_runtime.h" ] && [ -e "$cuda/lib64/libcudart.so" ] && command -v nvidia-smi >/dev/null; then
  export TMPDIR=$out NFCXX_BACKEND=gcc
  if "$root/nfcxx" -c -I"$cuda/include" src/enum.cu -o "$out/enum.o" > "$out/enum.log" 2>&1 \
     && "$root/nfcxx" "$out/enum.o" -L"$cuda/lib64" -lcudart -o "$out/enum" >> "$out/enum.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/enum") && [[ "$run" == "enum: 0 mismatches, host-only 7" ]]; then
    echo "enum run: $run"
  else
    echo "enum run: FAIL"; grep -v "pragma\|NV_SILENCE\|^ *\^\|warning\|^ *$" "$out/enum.log" | head -5; fail=1
  fi
fi
exit $fail
