#!/usr/bin/env bash
# nfcast, the self-specializing AST interpreter in lib/ast, on its own (docs/notes/ast.md): per back end, builds with nfcxx
#   - tests/ast/engine.cpp   checks through the C++ API (specialization counters, the collector, host objects, errors)
#   - tests/ast/tier.cpp     checks of the tier through the C++ API (what is compiled and when, bailouts, the cache, failures)
#   - tests/ast/driver.cpp   runs every tests/ast/cases/*.lua; its stdout must equal the .out file next to it, which a real
#                            Lua 5.4 wrote (tests/ast/regen.sh), in six configurations: with the inlining of small functions as it
#                            is by default, as early as possible (NFCAST_INLINE_WARM=1) and off (NFCAST_INLINE=0); with the tier on
#                            and every function compiled at its first call (NFCAST_TIER=sync, NFCAST_TIER_THRESHOLD=1), with and
#                            without early inlining; and with the tier compiling in the background (NFCAST_TIER=async), where
#                            which calls run as native code depends on timing and the output must not. The collector runs at its
#                            default; its forced-collection stress (NFCAST_GC_STRESS=1) is covered by engine.cpp and tier.cpp, not here
#   NFCXX_BACKEND=gcc|qbe   (default: both)
#   NFCAST_TIER_CACHE=dir   where the tier keeps the code it compiles (default: the library's, under $TMPDIR; a rerun reuses it)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
srcs=(lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp)
unset NFCAST_TIER NFCAST_TIER_THRESHOLD NFCAST_TIER_DEBUG NFCAST_GC_STRESS NFCAST_INLINE NFCAST_INLINE_WARM
export NFCXX="$PWD/nfcxx"   # the tier finds the driver itself, but the cases run from another directory
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  out=$tmp/$be; mkdir -p "$out"; objs=(); pids=(); bad=0
  for f in "${srcs[@]}" tests/ast/driver.cpp tests/ast/engine.cpp tests/ast/tier.cpp; do   # compile in parallel
    o=$out/$(basename "$f" .cpp).o; objs+=("$o")
    (NFCXX_BACKEND=$be ./nfcxx -c -O2 -I lib/ast "$f" -o "$o" > "$o.log" 2>&1) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || bad=1; done
  if [ $bad = 1 ]; then echo "FAIL $be ast (build)"; cat "$out"/*.log | grep -v prelinker | head -40; fail=1; continue; fi
  eng=(); drv=(); tie=()
  for o in "${objs[@]}"; do
    case $(basename "$o") in driver.o) drv+=("$o") ;; engine.o) eng+=("$o") ;; tier.o) tie+=("$o") ;; *) eng+=("$o"); drv+=("$o"); tie+=("$o") ;; esac
  done
  : > "$out/link.log"
  if ! NFCXX_BACKEND=$be ./nfcxx "${eng[@]}" -o "$out/engine" >> "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${tie[@]}" -o "$out/tier" >> "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${drv[@]}" -o "$out/driver" >> "$out/link.log" 2>&1; then
    echo "FAIL $be ast (link)"; head -20 "$out/link.log"; fail=1; continue
  fi
  res=$("$out/engine" 2>&1) || { echo "FAIL $be ast engine"; echo "$res" | head -30; fail=1; continue; }
  tres=$(NFCXX_BACKEND=$be "$out/tier" 2>&1) || { echo "FAIL $be ast tier"; echo "$tres" | head -30; fail=1; continue; }
  n=0
  for lua in tests/ast/cases/*.lua; do
    name=$(basename "$lua" .lua)
    for cfg in "0 NFCAST_INLINE=1 plain" "0 NFCAST_INLINE_WARM=1 inline-early" "0 NFCAST_INLINE=0 no-inline" \
               "sync NFCAST_INLINE=1 tier" "sync NFCAST_INLINE_WARM=1 tier+inline-early" \
               "async NFCAST_INLINE=1 tier-async"; do
      set -- $cfg; tier=$1; inl=$2; label=$3
      tag=$name.$label
      if ! (cd tests/ast/cases && env "$inl" NFCXX_BACKEND=$be NFCAST_TIER=$tier NFCAST_TIER_THRESHOLD=1 "$out/driver" "$name.lua" > "$out/$tag.out" 2> "$out/$tag.err") ||
         ! cmp -s "$out/$tag.out" "tests/ast/cases/$name.out"; then
        echo "FAIL $be ast case $name ($label)"; diff "tests/ast/cases/$name.out" "$out/$tag.out" | head -10; head -5 "$out/$tag.err"; fail=1
      fi
    done
    n=$((n + 1))
  done
  echo "ok   $be ast: $(tail -1 <<<"$res"); $n programs equal to Lua 5.4 (with inlining on, early and off, with the tier at threshold 1 (also with early inlining), and with it compiling in the background)"
  echo "ok   $be ast tier: $(tail -1 <<<"$tres")"
done
exit $fail
