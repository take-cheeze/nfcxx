#!/usr/bin/env bash
# nfcuop (lib/uop, docs/notes/uop.md), per back end built with nfcxx and run:
#   - tests/uop/test.cpp        scalar core: interning, interpreter, patterns, graph_rewrite, the symbolic simplifier, and a
#                               differential check of the simplifier against the interpreter on random expressions
#   - tests/uop/test_ut.cpp     shapes, movement ops (reshape, permute, expand, shrink, pad, flip), reductions, tensor rewrites
#                               (also differential), and the UOp-level numpy-style builder (nfcuop_ut.hpp)
#   - tests/uop/test_np.cpp     the user-facing numpy-like API over the ONNX-style graph (nfcuop_np.hpp, nfcuop_hir.hpp): values,
#                               errors, slicing, concatenation, the graph, the ONNX export; it also writes models
#   - tests/uop/test_onnx.cpp   the ONNX reader (hir::Graph::from_onnx / merge_onnx): export -> import -> export bytes equal, models made by
#                               the onnx package (tests/uop/onnx_import_gen.py) equal to onnxruntime, merging, name collisions, errors, Pad
#   - tests/uop/test_grad.cpp   reverse-mode autodiff by onnxsim (nfcuop_onnxgrad.hpp, docs/notes/uop-autodiff.md): finite differences in
#                               float64, exact gradients, second derivatives, the operators without a rule, errors, gradients on the C
#                               backend equal to the interpreter bit for bit; it also writes models (a loss and its gradients) for
#                               onnx_check.py. Needs onnxsim (build/onnxsim/libnfconnxsim.so from scripts/setup-onnxsim.sh, else python3
#                               with onnx and onnxsim==0.8.1) and prints SKIP without it
#   - tests/uop/test_cgen.cpp   C rendering (nfcuop_cgen.hpp): fusion, and generated C equal bit for bit to the interpreter on random
#                               graphs of every dtype and through the numpy API; the generated C is compiled with $NFCUOP_CC or cc.
#                               On the nfcxx back ends it is run a second time with `nfcxx` itself as the C compiler (the `quick` set)
#   - tests/uop/onnx_check.py   those models through onnx.checker and onnxruntime, against the UOp interpreter's results
#   - tests/uop/np_compat.cpp/.py   100 numpy expressions evaluated by nfcuop (interpreter and C) and by real numpy, compared; once
#                               with the 32-bit default dtypes (10 documented dtype differences) and once with float64/int64 (none)
#   - tests/uop/run_poly.sh     the API from scripts (lib/uop/nfcuop_poly.cpp, docs/notes/uop-poly.md): one model in Ruby, Lua, Python,
#                               JavaScript and Go, equal to the C++ API in values and in the bytes of the ONNX file; operators, errors,
#                               dtypes, the C backend. Languages that cannot be built here are skipped with a SKIP line
#   The two Python checks need numpy, onnx and onnxruntime and print SKIP when they are missing.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   UOP_HOST=1              build with the host g++ (-fsanitize=address,undefined) and nothing else; for a machine
#                           where nfcxx is not built
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
lib=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp)
tests=(test test_ut test_np test_onnx test_grad test_cgen np_compat)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# $1 label, $2 compile command prefix (words), rest unused; builds and runs everything with one compiler
run_all() {
  label=$1; shift
  mkdir -p "$tmp/$label/onnx" "$tmp/$label/import"
  command -v python3 >/dev/null && python3 tests/uop/onnx_import_gen.py "$tmp/$label/import" | sed "s/^/     $label /"
  for t in "${tests[@]}"; do
    ldx=()   # nfcxx programs export type_info vtables that break the exceptions inside libnfconnxsim.so: export nothing (scripts/onnxsim/exe.map)
    [ -n "$CC_IS_NFCXX" ] && [ "$t" = test_grad ] && ldx=(-Wl,--version-script=scripts/onnxsim/exe.map)
    if ! out=$("$@" -I lib/uop tests/uop/$t.cpp "${lib[@]}" -o "$tmp/$label/$t" -ldl "${ldx[@]}" 2>&1); then
      echo "FAIL $label uop/$t (build)"; head -30 <<<"$out"; fail=1; continue
    fi
    case $t in
      test_np|test_grad) args=("$tmp/$label/onnx") ;;
      test_onnx) args=("$tmp/$label/import") ;;
      np_compat) args=("$tmp/$label/compat.json") ;;
      *) args=() ;;
    esac
    if res=$("$tmp/$label/$t" "${args[@]}" 2>&1); then echo "ok   $label uop/$t: $(tail -1 <<<"$res")"; grep '^SKIP' <<<"$res" | sed "s/^/     $label /"
    else echo "FAIL $label uop/$t"; head -30 <<<"$res"; fail=1; fi
  done
  if res=$("$tmp/$label/np_compat" "$tmp/$label/compat64.json" 64 2>&1); then echo "ok   $label uop/np_compat (float64/int64 defaults): $(tail -1 <<<"$res")"
  else echo "FAIL $label uop/np_compat 64"; head -30 <<<"$res"; fail=1; fi
  if [ -n "$CC_IS_NFCXX" ]; then   # the generated C through the nfcxx driver
    if res=$(NFCUOP_CC="$PWD/nfcxx" "$tmp/$label/test_cgen" quick 2>&1); then echo "ok   $label uop/test_cgen with nfcxx as the C compiler: $(tail -1 <<<"$res")"
    else echo "FAIL $label uop/test_cgen with nfcxx as the C compiler"; head -30 <<<"$res"; fail=1; fi
  fi
  if command -v python3 >/dev/null; then
    python3 tests/uop/onnx_check.py "$tmp/$label/onnx" | sed "s/^/     $label /" ; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label onnx_check"; fail=1; }
    [ -f "$tmp/$label/compat.json" ] && { python3 tests/uop/np_compat.py "$tmp/$label/compat.json" | sed "s/^/     $label /"; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label np_compat"; fail=1; }; }
    [ -f "$tmp/$label/compat64.json" ] && { python3 tests/uop/np_compat.py "$tmp/$label/compat64.json" 64 | sed "s/^/     $label /"; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label np_compat 64"; fail=1; }; }
  fi
}
if [ -n "$UOP_HOST" ]; then
  run_all host g++ -std=c++17 -Wall -Wextra -O1 -fsanitize=address,undefined
  tests/uop/run_poly.sh || fail=1
  exit $fail
fi
for be in $backends; do
  CC_IS_NFCXX=1 NFCXX_BACKEND=$be run_all "$be" ./nfcxx -O2
done
tests/uop/run_poly.sh || fail=1   # the same API from Ruby, Lua, Python, JavaScript and Go (nfcpoly)
exit $fail
