#!/usr/bin/env bash
# nfcast, the self-specializing AST interpreter in lib/ast, on its own (docs/notes/ast.md): per back end, builds with nfcxx
#   - tests/ast/engine.cpp   checks through the C++ API (specialization counters, the collector, host objects, errors)
#   - tests/ast/driver.cpp   runs every tests/ast/cases/*.lua; its stdout must equal the .out file next to it, which a real
#                            Lua 5.4 wrote (tests/ast/regen.sh), once normally and once with the collector forced to run at
#                            every safe point (NFCAST_GC_STRESS=1)
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
srcs=(lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp)
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  out=$tmp/$be; mkdir -p "$out"; objs=(); pids=(); bad=0
  for f in "${srcs[@]}" tests/ast/driver.cpp tests/ast/engine.cpp; do   # compile in parallel
    o=$out/$(basename "$f" .cpp).o; objs+=("$o")
    (NFCXX_BACKEND=$be ./nfcxx -c -O2 -I lib/ast "$f" -o "$o" > "$o.log" 2>&1) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || bad=1; done
  if [ $bad = 1 ]; then echo "FAIL $be ast (build)"; cat "$out"/*.log | grep -v prelinker | head -40; fail=1; continue; fi
  eng=(); drv=()
  for o in "${objs[@]}"; do
    case $(basename "$o") in driver.o) drv+=("$o") ;; engine.o) eng+=("$o") ;; *) eng+=("$o"); drv+=("$o") ;; esac
  done
  if ! NFCXX_BACKEND=$be ./nfcxx "${eng[@]}" -o "$out/engine" > "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${drv[@]}" -o "$out/driver" >> "$out/link.log" 2>&1; then
    echo "FAIL $be ast (link)"; head -20 "$out/link.log"; fail=1; continue
  fi
  res=$("$out/engine" 2>&1) || { echo "FAIL $be ast engine"; echo "$res" | head -30; fail=1; continue; }
  n=0
  for lua in tests/ast/cases/*.lua; do
    name=$(basename "$lua" .lua)
    for stress in 0 1; do
      for inl in "NFCAST_INLINE=1" "NFCAST_INLINE_WARM=1" "NFCAST_INLINE=0"; do
        if ! (cd tests/ast/cases && env "$inl" NFCAST_GC_STRESS=$stress "$out/driver" "$name.lua" > "$out/$name.$stress.out" 2> "$out/$name.$stress.err") ||
           ! cmp -s "$out/$name.$stress.out" "tests/ast/cases/$name.out"; then
          echo "FAIL $be ast case $name (GC stress $stress, $inl)"; diff "tests/ast/cases/$name.out" "$out/$name.$stress.out" | head -10; head -5 "$out/$name.$stress.err"; fail=1
        fi
      done
    done
    n=$((n + 1))
  done
  echo "ok   $be ast: $(tail -1 <<<"$res"); $n programs equal to Lua 5.4 (also under GC stress, with inlining on, early and off)"
done
exit $fail
