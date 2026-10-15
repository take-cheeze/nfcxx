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
pass fnptr_addr.cu "fnptr addr: 0 mismatches"
pass init_list_range.cu "init list: no error, 0 mismatches"
# Mutant: the flag compares against the wrong function, so the check must see a mismatch.
if "$root/nfcxx" -c -I"$cuda/include" fnptr_addr_mutant.cu -o "$out/fam.o" > "$out/fam.log" 2>&1 \
   && "$root/nfcxx" "$out/fam.o" -L"$cuda/lib64" -lcudart -o "$out/fam" >> "$out/fam.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/fam" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant fnptr_addr_mutant: caught: $run"
else
  echo "FAIL fnptr_addr_mutant: the mutant was not caught"; fail=1
fi
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
pass vec4_alignas.cu "vec4 alignas: no error, 0 mismatches"
# Mutant: the sum drops its last element, so the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" vec4_alignas_mutant.cu -o "$out/vm.o" > "$out/vm.log" 2>&1 \
   && "$root/nfcxx" "$out/vm.o" -L"$cuda/lib64" -lcudart -o "$out/vm" >> "$out/vm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/vm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant vec4_alignas: caught: $run"
else
  echo "FAIL vec4_alignas: the mutant was not caught"; fail=1
fi
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
pass nested_fnptr.cu "nested fnptr: 0 mismatches"
# Mutant: the quantizer triples, so the check against the doubled values must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" nested_fnptr_mutant.cu -o "$out/nfm.o" > "$out/nfm.log" 2>&1 \
   && "$root/nfcxx" "$out/nfm.o" -L"$cuda/lib64" -lcudart -o "$out/nfm" >> "$out/nfm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/nfm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant nested_fnptr_mutant: caught: $run"
else
  echo "FAIL nested_fnptr_mutant: the mutant was not caught"; fail=1
fi
pass bare_dim.cu "bare dim: exact"
# Mutant: the kernel adds 8 where the host expects 7, so the check must see a mismatch.
if "$root/nfcxx" -c -I"$cuda/include" bare_dim_mutant.cu -o "$out/bdm.o" > "$out/bdm.log" 2>&1 \
   && "$root/nfcxx" "$out/bdm.o" -L"$cuda/lib64" -lcudart -o "$out/bdm" >> "$out/bdm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/bdm" || true) \
   && [[ "$run" == *"mismatch"* ]]; then
  echo "mutant bare_dim: caught: $run"
else
  echo "FAIL bare_dim: the mutant was not caught"; fail=1
fi
pass pack_trailing.cu "pack trailing: no error, 0 mismatches"
# Mutant: the kernel adds 1 to every output, so the check must see one mismatch.
if "$root/nfcxx" -c -I"$cuda/include" pack_trailing_mutant.cu -o "$out/pt.o" > "$out/pt.log" 2>&1 \
   && "$root/nfcxx" "$out/pt.o" -L"$cuda/lib64" -lcudart -o "$out/pt" >> "$out/pt.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/pt" || true) \
   && [[ "$run" == *"1 mismatches"* ]]; then
  echo "mutant pack_trailing: caught: $run"
else
  echo "FAIL pack_trailing mutant: not caught"; fail=1
fi
pass alias_fnptr.cu "alias fnptr: no error, 0 mismatches"
# Mutant: the kernel scales by 3 instead of 2, so the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" alias_fnptr_mutant.cu -o "$out/af.o" > "$out/af.log" 2>&1 \
   && "$root/nfcxx" "$out/af.o" -L"$cuda/lib64" -lcudart -o "$out/af" >> "$out/af.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/af" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant alias_fnptr: caught: $run"
else
  echo "FAIL alias_fnptr mutant: not caught"; fail=1
fi
# Emitter lowerings: bool kernel parameter, bool device-function argument, bool to float, volatile store and load.
pass emit_misc.cu "emit misc: no error, 0 mismatches"
# Mutant: the device function's bool test is flipped, so the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" emit_misc_mutant.cu -o "$out/emm.o" > "$out/emm.log" 2>&1 \
   && "$root/nfcxx" "$out/emm.o" -L"$cuda/lib64" -lcudart -o "$out/emm" >> "$out/emm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/emm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant emit_misc: caught: $run"
else
  echo "FAIL emit_misc mutant: not caught"; fail=1
fi
# Kernel instances whose addresses are taken (a ternary, and a dependent one in a template), launched by address.
pass addr_taken.cu "addr taken: 0 mismatches"
# Mutant: the ternary selects the same instance twice, so the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" addr_taken_mutant.cu -o "$out/atm.o" > "$out/atm.log" 2>&1 \
   && "$root/nfcxx" "$out/atm.o" -L"$cuda/lib64" -lcudart -o "$out/atm" >> "$out/atm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/atm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant addr_taken: caught: $run"
else
  echo "FAIL addr_taken mutant: not caught"; fail=1
fi
# Address sites under `if constexpr (cond)`: a constexpr function of the unit decides each instance's site.
pass constexpr_guard.cu "constexpr guard: 0 mismatches"
# Mutant: the condition is negated, so the instances take the other sites, and the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" constexpr_guard_mutant.cu -o "$out/cgm.o" > "$out/cgm.log" 2>&1 \
   && "$root/nfcxx" "$out/cgm.o" -L"$cuda/lib64" -lcudart -o "$out/cgm" >> "$out/cgm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/cgm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant constexpr_guard: caught: $run"
else
  echo "FAIL constexpr_guard mutant: not caught"; fail=1
fi
pass helper_launch.cu "helper launch: no error, 0 mismatches"
# Mutant: the helper launches the wrong template instance, so every element must mismatch.
if "$root/nfcxx" -c -I"$cuda/include" helper_launch_mutant.cu -o "$out/hlm.o" > "$out/hlm.log" 2>&1 \
   && "$root/nfcxx" "$out/hlm.o" -L"$cuda/lib64" -lcudart -o "$out/hlm" >> "$out/hlm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/hlm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant helper_launch_mutant: caught: $run"
else
  echo "FAIL helper_launch_mutant: the mutant was not caught"; fail=1
fi
# Dynamic shared array as an operand of a multiplication (`s * meta[l].y`): not a pointer declaration.
pass dynshared_operator.cu "dynshared operator: no error, 0 mismatches"
if "$root/nfcxx" -c -I"$cuda/include" dynshared_operator_mutant.cu -o "$out/dom.o" > "$out/dom.log" 2>&1 \
   && "$root/nfcxx" "$out/dom.o" -L"$cuda/lib64" -lcudart -o "$out/dom" >> "$out/dom.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/dom" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant dynshared_operator: caught: $run"
else
  echo "FAIL dynshared_operator mutant: not caught"; fail=1
fi
# Mutant: one stride is wrong (w/8 for w/4), so the kernel's sums differ and the check must see mismatches.
if "$root/nfcxx" -c -I"$cuda/include" init_list_range_mutant.cu -o "$out/ilm.o" > "$out/ilm.log" 2>&1 \
   && "$root/nfcxx" "$out/ilm.o" -L"$cuda/lib64" -lcudart -o "$out/ilm" >> "$out/ilm.log" 2>&1 \
   && run=$(LD_LIBRARY_PATH="$cuda/lib64:/usr/lib/x86_64-linux-gnu" "$out/ilm" || true) \
   && [[ "$run" == *"mismatches"* && "$run" != *" 0 mismatches"* ]]; then
  echo "mutant init_list_range_mutant: caught: $run"
else
  echo "FAIL init_list_range_mutant: the mutant was not caught"; fail=1
fi
exit $fail
