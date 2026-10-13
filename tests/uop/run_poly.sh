#!/usr/bin/env bash
# nfcuop from scripts (lib/uop/nfcuop_poly.cpp, docs/notes/uop-poly.md): tests/uop/test_poly.cpp builds the same model in Ruby, Lua,
# Python, JavaScript and Go through nfcpoly and checks the values, the exported ONNX bytes, the operators, the errors, the dtype
# configuration and the C backend against the C++ API. Run by tests/uop/run.sh; per back end built with nfcxx, the interpreters from
# the setup scripts of tests/poly/run.sh.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   POLY_LANGS="ruby lua python js go"   (default: all five; one that cannot be built here is skipped with a SKIP line)
#   UOP_HOST=1              build with the host g++ and the interpreters of scripts/setup-poly-host.sh (mruby, Lua and QuickJS built
#                           with gcc; Go as scripts/setup-poly-go.sh builds it; the system CPython), for a machine where nfcxx is
#                           not built. No sanitizers: the interpreters are not clean under them.
#   UOP_POLY_OUT=DIR        keep the test program as DIR/test_poly-<label>
# The model that test writes (model.onnx and model.json, built by the first language) is checked by tests/uop/onnx_check.py when numpy, onnx and
# onnxruntime are installed (SKIP otherwise).
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
langs=${POLY_LANGS:-"ruby lua python js go"}
lib=(lib/uop/nfcuop.cpp lib/uop/nfcuop_pattern.cpp lib/uop/nfcuop_symbolic.cpp lib/uop/nfcuop_ut.cpp lib/uop/nfcuop_sym_expr.cpp lib/uop/nfcuop_shaping.cpp lib/uop/nfcuop_hir.cpp lib/uop/nfcuop_lower.cpp
     lib/uop/nfcuop_np.cpp lib/uop/nfcuop_cgen.cpp lib/uop/nfcuop_onnx_import.cpp lib/uop/nfcuop_onnxgrad.cpp lib/uop/nfcuop_poly.cpp lib/poly/nfcpoly.cpp)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# run_with LABEL BACKEND|host: gathers the languages, builds, runs
run_with() {
  label=$1; be=$2
  defs=(); incs=(-I lib/uop -I lib/poly); srcs=(); libs=(); built=(); bad=0
  for l in $langs; do
    case $l in
      ruby)
        if [ "$be" = host ]; then
          out=$(scripts/setup-poly-host.sh ruby 2>&1); rc=$?
          if [ $rc = 3 ]; then echo "SKIP $label uop/poly ruby: $(tail -1 <<<"$out" | sed 's/^setup-poly-host: //')"; continue
          elif [ $rc != 0 ]; then echo "FAIL $label uop/poly ruby (mruby build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly-host/ruby
        else
          if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly.sh 2>&1); then echo "FAIL $label uop/poly ruby (mruby build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly/$be
        fi
        defs+=(-DTEST_RUBY); incs+=(-I $dir/include); srcs+=(lib/poly/nfcpoly_mruby.cpp); libs+=($dir/lib/libmruby.a); built+=(ruby) ;;
      lua)
        if [ "$be" = host ]; then
          out=$(scripts/setup-poly-host.sh lua 2>&1); rc=$?
          if [ $rc = 3 ]; then echo "SKIP $label uop/poly lua: $(tail -1 <<<"$out" | sed 's/^setup-poly-host: //')"; continue
          elif [ $rc != 0 ]; then echo "FAIL $label uop/poly lua (Lua build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly-host/lua
        else
          if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly-lua.sh 2>&1); then echo "FAIL $label uop/poly lua (Lua build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly-lua/$be
        fi
        defs+=(-DTEST_LUA); incs+=(-I $dir/include); srcs+=(lib/poly/nfcpoly_lua.cpp); libs+=($dir/lib/liblua.a); built+=(lua) ;;
      js)
        if [ "$be" = host ]; then
          out=$(scripts/setup-poly-host.sh js 2>&1); rc=$?
          if [ $rc = 3 ]; then echo "SKIP $label uop/poly js: $(tail -1 <<<"$out" | sed 's/^setup-poly-host: //')"; continue
          elif [ $rc != 0 ]; then echo "FAIL $label uop/poly js (QuickJS build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly-host/js
        else
          if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly-js.sh 2>&1); then echo "FAIL $label uop/poly js (QuickJS build)"; tail -20 <<<"$out"; bad=1; continue; fi
          dir=build/poly-js/$be
        fi
        defs+=(-DTEST_JS); incs+=(-I $dir/include); srcs+=(lib/poly/nfcpoly_js.cpp); libs+=($dir/lib/libquickjs.a); built+=(js) ;;
      python)
        if command -v python3-config >/dev/null && pyinc=$(python3-config --includes 2>/dev/null) && pylib=$(python3-config --ldflags --embed 2>/dev/null) &&
           [ -f "$(python3-config --includes | sed 's/^-I\([^ ]*\).*/\1/')/Python.h" ]; then
          defs+=(-DTEST_PYTHON); incs+=($pyinc); srcs+=(lib/poly/nfcpoly_python.cpp); libs+=($pylib); built+=(python)
        else
          echo "SKIP $label uop/poly python: python3-config or Python.h not found (apt-get install python3-dev)"
        fi ;;
      go)
        out=$(scripts/setup-poly-go.sh 2>&1); rc=$?
        if [ $rc = 3 ]; then echo "SKIP $label uop/poly go: $(tail -1 <<<"$out" | sed 's/^setup-poly-go: //')"; continue
        elif [ $rc != 0 ]; then echo "FAIL $label uop/poly go (libnfcgo build)"; tail -20 <<<"$out"; bad=1; continue; fi
        defs+=(-DTEST_GO); srcs+=(lib/poly/nfcpoly_go.cpp); libs+=(-Lbuild/poly-go -lnfcgo "-Wl,-rpath,$PWD/build/poly-go"); built+=(go) ;;
      *) echo "FAIL uop/poly: unknown language $l"; bad=1 ;;
    esac
  done
  [ $bad = 0 ] || { fail=1; return; }
  [ ${#built[@]} -gt 0 ] || { echo "SKIP $label uop/poly: no language available"; return; }
  mkdir -p "$tmp/$label/onnx"
  if [ "$be" = host ]; then cc=(g++ -std=c++17 -O1 -Wall -Wextra); extra=(-ldl -lpthread -lm); else cc=(./nfcxx -O2); extra=(-ldl); fi
  if ! out=$(NFCXX_BACKEND=$be "${cc[@]}" "${defs[@]}" "${incs[@]}" tests/uop/test_poly.cpp "${lib[@]}" "${srcs[@]}" "${libs[@]}" "${extra[@]}" -o "$tmp/$label/test_poly" 2>&1); then
    echo "FAIL $label uop/test_poly (build)"; grep -v 'prelinker' <<<"$out" | head -40; fail=1; return
  fi
  [ -z "${UOP_POLY_OUT:-}" ] || { mkdir -p "$UOP_POLY_OUT" && cp "$tmp/$label/test_poly" "$UOP_POLY_OUT/test_poly-$label"; }
  if res=$("$tmp/$label/test_poly" "$tmp/$label/onnx" 2>&1); then
    echo "ok   $label uop/test_poly [${built[*]}]: $(tail -1 <<<"$res")"
  else
    echo "FAIL $label uop/test_poly [${built[*]}]"; head -60 <<<"$res"; fail=1; return
  fi
  if command -v python3 >/dev/null; then
    python3 tests/uop/onnx_check.py "$tmp/$label/onnx" | sed "s/^/     $label poly /"
    [ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL $label poly onnx_check"; fail=1; }
  fi
}

if [ -n "$UOP_HOST" ]; then
  run_with host host
  exit $fail
fi
for be in $backends; do
  run_with "$be" "$be"
done
exit $fail
