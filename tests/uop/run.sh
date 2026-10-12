#!/usr/bin/env bash
# nfcuop (lib/uop, docs/notes/uop.md), per back end built with nfcxx and run:
#   - tests/uop/test.cpp        scalar core: interning, interpreter, patterns, graph_rewrite, the symbolic simplifier, and a
#                               differential check of the simplifier against the interpreter on random expressions
#   - tests/uop/test_ut.cpp     shapes, movement ops (reshape, permute, expand, shrink, pad, flip), reductions, tensor rewrites
#                               (also differential), and the UOp-level numpy-style builder (nfcuop_ut.hpp)
#   - tests/uop/test_np.cpp     the user-facing numpy-like API over the ONNX-style graph (nfcuop_np.hpp, nfcuop_hir.hpp): values,
#                               errors, slicing, concatenation, the graph, the ONNX export; it also writes models
#   - tests/uop/onnx_check.py   those models through onnx.checker and onnxruntime, against the UOp interpreter's results
#   - tests/uop/np_compat.cpp/.py   100 numpy expressions evaluated by nfcuop and by real numpy, compared
#   The two Python checks need numpy, onnx and onnxruntime and print SKIP when they are missing.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   UOP_HOST=1              build with the host g++ (-fsanitize=address,undefined) and nothing else; for a machine
#                           where nfcxx is not built
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
lib=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp lib/uop/nfcuop_np.cpp)
tests=(test test_ut test_np np_compat)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# $1 label, $2 compile command prefix (words), rest unused; builds and runs everything with one compiler
run_all() {
  label=$1; shift
  mkdir -p "$tmp/$label/onnx"
  for t in "${tests[@]}"; do
    if ! out=$("$@" -I lib/uop tests/uop/$t.cpp "${lib[@]}" -o "$tmp/$label/$t" 2>&1); then
      echo "FAIL $label uop/$t (build)"; head -30 <<<"$out"; fail=1; continue
    fi
    case $t in
      test_np) args=("$tmp/$label/onnx") ;;
      np_compat) args=("$tmp/$label/compat.json") ;;
      *) args=() ;;
    esac
    if res=$("$tmp/$label/$t" "${args[@]}" 2>&1); then echo "ok   $label uop/$t: $(tail -1 <<<"$res")"
    else echo "FAIL $label uop/$t"; head -30 <<<"$res"; fail=1; fi
  done
  if command -v python3 >/dev/null; then
    python3 tests/uop/onnx_check.py "$tmp/$label/onnx" | sed "s/^/     $label /" ; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label onnx_check"; fail=1; }
    [ -f "$tmp/$label/compat.json" ] && { python3 tests/uop/np_compat.py "$tmp/$label/compat.json" | sed "s/^/     $label /"; [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label np_compat"; fail=1; }; }
  fi
}
if [ -n "$UOP_HOST" ]; then
  run_all host g++ -std=c++17 -Wall -Wextra -O1 -fsanitize=address,undefined
  exit $fail
fi
for be in $backends; do
  NFCXX_BACKEND=$be run_all "$be" ./nfcxx -O2
done
exit $fail
