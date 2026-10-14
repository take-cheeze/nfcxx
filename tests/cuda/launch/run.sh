#!/usr/bin/env bash
# Launch-path features of llama.cpp's CUDA backend, through the nfcxx driver (see docs/notes/gpu.md, "Launch path").
#   pass:    builds, links, runs on the GPU, and prints the expected line.
#   refuse:  the driver refuses with exit 3 and the message names the gap (the work is not done yet).
#   (Dependent launches: the enclosing template's concrete instances come from its explicit calls in the unit.)
# Needs the CUDA toolkit (CUDA_HOME, default /usr/local/cuda) and an NVIDIA GPU; skips (exit 0) when missing.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
cuda=${CUDA_HOME:-/usr/local/cuda}
if [ ! -f "$cuda/include/cuda_runtime.h" ] || [ ! -e "$cuda/lib64/libcudart.so" ] || ! command -v nvidia-smi >/dev/null; then
  echo "SKIP: launch: needs cuda_runtime.h, libcudart and nvidia-smi (CUDA_HOME)"; exit 0
fi
fail=0
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
export TMPDIR=$out

pass() {  # pass FILE.cu EXPECTED-SUBSTRING
  local src=$1 want=$2 name
  name=$(basename "$src" .cu)
  if "$root/nfcxx" -c -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 \
     && "$root/nfcxx" "$out/$name.o" -L"$cuda/lib64" -lcudart -o "$out/$name" >> "$out/$name.log" 2>&1 \
     && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/$name") && [[ "$run" == *"$want"* ]]; then
    echo "pass $name: $run"
  else
    echo "FAIL $name"; grep -v "pragma\|NV_SILENCE\|^ *\^\|^ *$\|warning" "$out/$name.log" | head -5; fail=1
  fi
}

refuse() {  # refuse FILE.cu MESSAGE-SUBSTRING
  local src=$1 want=$2 name rc=0
  name=$(basename "$src" .cu)
  "$root/nfcxx" -c -I"$cuda/include" "$src" -o "$out/$name.o" > "$out/$name.log" 2>&1 || rc=$?
  if [ "$rc" = 3 ] && grep -q "$want" "$out/$name.log"; then
    echo "refused $name: $(grep -m1 "$want" "$out/$name.log" | cut -c1-160)"
  else
    echo "FAIL refused $name (exit $rc, expected 3 with: $want)"; fail=1
  fi
}

pass bounds.cu "launch_bounds: no error, 0 mismatches"
pass async.cu "async: no error, 0 mismatches"
pass decl_macro.cu "decl macro: no error, 14"
pass enum_extern_block.cu "enum extern block: no error, 0 mismatches"
pass local_const.cu "local const: no error, 41 40"
pass dynshared.cu "dynamic shared: no error, 0 mismatches"
pass host_cub_helper.cu "host cub helper: no error, 0 mismatches"
pass linkage_block.cu "linkage block: no error, 0 mismatches"
pass macro_launch.cu "macro launch: no error, value 3"
pass deduced_launch.cu "deduced launch: no error, value 3.0"
pass member_launch.cu "member launch: no error, value 7.0"
pass deduce_expr.cu "deduced launch: no error, value 3.0"
pass deduce_cast.cu "deduce cast: no error, sum 38.0"
refuse refuse_member_nocall.cu "depends on the template parameter Real of run"
pass tmpl_explicit.cu "templates: no error, 0 mismatches"
pass tmpl_dep.cu "template dependent: no error, 0 mismatches"
pass dep_type.cu "dep type: no error, 0 mismatches"
pass dep_value.cu "dep value: no error, 0 mismatches"
pass generic_lambda.cu "generic lambda: no error, 102 105 107"
pass fold_pack.cu "fold pack: no error, 1 1 1 0 314"
refuse refuse_dep_nocall.cu "instances are not known"
refuse refuse_dep_cycle.cu "instantiates itself through its template arguments"
refuse refuse_generic_lambda.cu "is called with an argument that is not a literal"
pass deduce_single.cu "deduce single: no error, value 1"
pass pack.cu "pack: no error, 0 mismatches"
pass deduce.cu "deduce: no error, 0 mismatches"
refuse deduce_ambiguous.cu "call of run2: T is deduced as float and as int (ambiguous"
refuse pack_refuse.cu "no argument gives Ns, so it cannot be deduced"
pass local_targs.cu "local targs: no error, 43 43"
pass macro_targs.cu "macro targs: no error, 64 64"
pass using_namespace.cu "using namespace: no error, 28 28"
pass shared_align.cu "shared align launch: no error, 0 mismatches"
pass grid_sync.cu "grid sync: no error, 0 mismatches"
# Mutant: the same two-phase kernel without the grid barrier must read stale data, so the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" grid_sync_nobarrier.cu -o "$out/nb.o" > "$out/nb.log" 2>&1 \
   && "$root/nfcxx" "$out/nb.o" -L"$cuda/lib64" -lcudart -o "$out/nb" >> "$out/nb.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/nb" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant grid_sync_nobarrier: caught: $run"
else
  echo "FAIL grid_sync_nobarrier: the mutant was not caught"; fail=1
fi
pass overload_pair.cu "overload pair: exact"
pass fnptr_return.cu "fnptr return: exact"
exit $fail
