#!/usr/bin/env bash
# nfcpoly: build the host test (tests/poly/host.cpp with lib/poly/nfcpoly.cpp and the language backends) with nfcxx and run
# it, per back end. The languages' interpreters are built per back end by scripts/setup-poly.sh (mruby with C++
# exceptions), scripts/setup-poly-lua.sh (Lua with ldo.c as C++) and scripts/setup-poly-js.sh (QuickJS, plain C); Python is the
# system CPython (python3-config), and is skipped with a SKIP line when its development files are missing. See docs/notes/poly.md.
#   NFCXX_BACKEND=gcc|qbe          (default: both)
#   POLY_LANGS="ruby lua python ast js"   (default: all five; ast is the nfcast engine, lib/ast, which needs nothing built)
#   POLY_OUT=DIR                   keep the built hosts as DIR/host-<backend> (to run them under valgrind: PYTHONMALLOC=malloc)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
langs=${POLY_LANGS:-"ruby lua python ast js"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  defs=(); incs=(-I lib/poly); srcs=(); libs=(); built=(); bad=0
  for l in $langs; do
    case $l in
      ruby)
        if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly.sh 2>&1); then echo "FAIL $be poly ruby (mruby build)"; tail -20 <<<"$out"; bad=1; continue; fi
        defs+=(-DTEST_RUBY); incs+=(-I build/poly/$be/include); srcs+=(lib/poly/nfcpoly_mruby.cpp); libs+=(build/poly/$be/lib/libmruby.a); built+=(ruby) ;;
      lua)
        if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly-lua.sh 2>&1); then echo "FAIL $be poly lua (Lua build)"; tail -20 <<<"$out"; bad=1; continue; fi
        defs+=(-DTEST_LUA); incs+=(-I build/poly-lua/$be/include); srcs+=(lib/poly/nfcpoly_lua.cpp); libs+=(build/poly-lua/$be/lib/liblua.a); built+=(lua) ;;
      js)
        if ! out=$(NFCXX_BACKEND=$be scripts/setup-poly-js.sh 2>&1); then echo "FAIL $be poly js (QuickJS build)"; tail -20 <<<"$out"; bad=1; continue; fi
        defs+=(-DTEST_JS); incs+=(-I build/poly-js/$be/include); srcs+=(lib/poly/nfcpoly_js.cpp); libs+=(build/poly-js/$be/lib/libquickjs.a); built+=(js) ;;
      python)
        if command -v python3-config >/dev/null && pyinc=$(python3-config --includes 2>/dev/null) && pylib=$(python3-config --ldflags --embed 2>/dev/null) &&
           [ -f "$(python3-config --includes | sed 's/^-I\([^ ]*\).*/\1/')/Python.h" ]; then
          defs+=(-DTEST_PYTHON); incs+=($pyinc); srcs+=(lib/poly/nfcpoly_python.cpp); libs+=($pylib); built+=(python)
        else
          echo "SKIP $be poly python: python3-config or Python.h not found (apt-get install python3-dev)"
        fi ;;
      ast)
        defs+=(-DTEST_AST); incs+=(-I lib/ast); srcs+=(lib/poly/nfcpoly_ast.cpp lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp); built+=(ast) ;;
      *) echo "FAIL poly: unknown language $l"; bad=1 ;;
    esac
  done
  [ $bad = 0 ] || { fail=1; continue; }
  [ ${#built[@]} -gt 0 ] || { echo "SKIP $be poly: no language available"; continue; }
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx "${defs[@]}" "${incs[@]}" tests/poly/host.cpp lib/poly/nfcpoly.cpp "${srcs[@]}" "${libs[@]}" -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be poly (host build)"; grep -v 'prelinker' <<<"$out" | head -40; fail=1; continue
  fi
  [ -z "${POLY_OUT:-}" ] || { mkdir -p "$POLY_OUT" && cp "$tmp/host-$be" "$POLY_OUT/host-$be"; }
  if out=$("$tmp/host-$be" 2>&1); then
    echo "ok   $be poly [${built[*]}]: $(tail -1 <<<"$out")"
  else
    echo "FAIL $be poly [${built[*]}]"; head -60 <<<"$out"; fail=1
  fi
done
exit $fail
