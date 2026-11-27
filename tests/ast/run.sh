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
#   - tests/ast/counts/loop.lua  the node-evaluation count (State::stats.node_evals, in a -DNFCAST_COUNT_NODES build) of a known program: 28
#   NFCXX_BACKEND=pathb|gcc|qbe   (default: pathb and gcc)
#                            cases/inline_loops.lua ends in a deep recursion (pcall of an infinite one) that the engine cuts at
#                            State::max_depth = 1500 levels, a depth it sizes for about 1 KB of C++ stack per level: on Path B it needs
#                            the stack of the frames of the SSA route (docs/notes/pathb-ssa-qbe.md, "Frames"), not gcc's
#   - tests/ast/jit.cpp      the machine-code tier for loops (docs/notes/ast.md, "JIT") against the interpreter, with its counters;
#                            the driver cases also run once with the tier on and --jit (the seventh configuration)
#   NFCAST_TIER_CACHE=dir   where the tier keeps the code it compiles (default: the library's, under $TMPDIR; a rerun reuses it)
#   LUA   a Lua 5.4.9 interpreter (optional). When set, the programs of tests/ast/cases and tests/ast/bytecode/cases are dumped with
#         string.dump and each dump is run (plain, with forced collection, and with the tier at threshold 1); the dump must print what
#         the .out next to the source says. tests/ast/bytecode/stack.lua checks the stack functions of a bytecode frame, and
#         refuse.lua (a to-be-closed variable) must be refused at load time (docs/notes/ast.md, "Bytecode"). Without LUA this is skipped
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"pathb gcc"}
srcs=(lib/ast/nfcast_core.cpp lib/ast/nfcast_ops.cpp lib/ast/nfcast_parse.cpp lib/ast/nfcast_nodes.cpp lib/ast/nfcast_lib.cpp lib/ast/nfcast_tier.cpp lib/ast/nfcast_jit.cpp lib/ast/nfcast_bytecode.cpp tools/lua54bc/lua54_chunk.cpp)
unset NFCAST_TIER NFCAST_TIER_THRESHOLD NFCAST_TIER_DEBUG NFCAST_GC_STRESS NFCAST_INLINE NFCAST_INLINE_WARM
export NFCXX="$PWD/nfcxx"   # the tier finds the driver itself, but the cases run from another directory
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for be in $backends; do
  out=$tmp/$be; mkdir -p "$out"; objs=(); pids=(); bad=0
  for f in "${srcs[@]}" tests/ast/driver.cpp tests/ast/engine.cpp tests/ast/tier.cpp tests/ast/jit.cpp; do   # compile in parallel
    o=$out/$(basename "$f" .cpp).o; objs+=("$o")
    (NFCXX_BACKEND=$be ./nfcxx -c -O2 -I lib/ast "$f" -o "$o" > "$o.log" 2>&1) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || bad=1; done
  if [ $bad = 1 ]; then echo "FAIL $be ast (build)"; cat "$out"/*.log | grep -v prelinker | head -40; fail=1; continue; fi
  eng=(); drv=(); tie=(); jt=()
  for o in "${objs[@]}"; do
    case $(basename "$o") in driver.o) drv+=("$o") ;; engine.o) eng+=("$o") ;; tier.o) tie+=("$o") ;; jit.o) jt+=("$o") ;; *) eng+=("$o"); drv+=("$o"); tie+=("$o"); jt+=("$o") ;; esac
  done
  : > "$out/link.log"
  if ! NFCXX_BACKEND=$be ./nfcxx "${eng[@]}" -o "$out/engine" >> "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${tie[@]}" -o "$out/tier" >> "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${jt[@]}" -o "$out/jit" >> "$out/link.log" 2>&1 ||
     ! NFCXX_BACKEND=$be ./nfcxx "${drv[@]}" -o "$out/driver" >> "$out/link.log" 2>&1; then
    echo "FAIL $be ast (link)"; head -20 "$out/link.log"; fail=1; continue
  fi
  res=$("$out/engine" 2>&1) || { echo "FAIL $be ast engine"; echo "$res" | head -30; fail=1; continue; }
  tres=$(NFCXX_BACKEND=$be "$out/tier" 2>&1) || { echo "FAIL $be ast tier"; echo "$tres" | head -30; fail=1; continue; }
  jres=$(NFCXX_BACKEND=$be "$out/jit" 2>&1) || { echo "FAIL $be ast jit"; echo "$jres" | head -40; fail=1; continue; }
  n=0
  for lua in tests/ast/cases/*.lua; do
    name=$(basename "$lua" .lua)
    for cfg in "0 NFCAST_INLINE=1 plain" "0 NFCAST_INLINE_WARM=1 inline-early" "0 NFCAST_INLINE=0 no-inline" \
               "sync NFCAST_INLINE=1 tier" "sync NFCAST_INLINE_WARM=1 tier+inline-early" \
               "async NFCAST_INLINE=1 tier-async" "sync NFCAST_INLINE=1 tier+jit --jit"; do
      set -- $cfg; tier=$1; inl=$2; label=$3; jit=${4:-}
      tag=$name.$label
      if ! (cd tests/ast/cases && env "$inl" NFCXX_BACKEND=$be NFCAST_TIER=$tier NFCAST_TIER_THRESHOLD=1 "$out/driver" $jit "$name.lua" > "$out/$tag.out" 2> "$out/$tag.err") ||
         ! cmp -s "$out/$tag.out" "tests/ast/cases/$name.out"; then
        echo "FAIL $be ast case $name ($label)"; diff "tests/ast/cases/$name.out" "$out/$tag.out" | head -10; head -5 "$out/$tag.err"; fail=1
      fi
    done
    n=$((n + 1))
  done
  echo "ok   $be ast: $(tail -1 <<<"$res"); $n programs equal to Lua 5.4 (with inlining on, early and off, with the tier at threshold 1 (also with early inlining), and with it compiling in the background)"
  echo "ok   $be ast tier: $(tail -1 <<<"$tres")"
  echo "ok   $be ast jit: $(tail -1 <<<"$jres")"
  # The profile of the tier (docs/notes/profiler.md, "Next steps", item 4): with NFCAST_TIER_PROFILE=1 the compiled functions call the
  # profiler runtime, and NFCXX_PROFILE gets their enters and exits (tests/prof/check_any.c checks them). Each case compiles one shared
  # object, which carries the runtime, so each writes the profile itself. Without the switch no profile is written.
  gcc -std=c11 -O2 -Wall -Wextra -Werror tests/prof/check_any.c -o "$out/check_any" || { echo "FAIL $be ast profile (check_any)"; fail=1; }
  prof_ok=1
  rm -f "$out/fib.prof"
  if ! (cd tests/ast/profile && env NFCXX_BACKEND=$be NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCAST_TIER_PROFILE=1 NFCXX_PROFILE="$out/fib.prof" "$out/driver" fib.lua > "$out/fib.out" 2> "$out/fib.err") ||
     ! grep -qx "6765" "$out/fib.out" || ! "$out/check_any" "$out/fib.prof" | grep -q "sites=1 pairs=21891 threads=1"; then
    echo "FAIL $be ast profile fib"; head -5 "$out/fib.err"; "$out/check_any" "$out/fib.prof" 2>&1 | head -3; prof_ok=0; fail=1
  fi
  rm -f "$out/abort.prof"
  if ! (cd tests/ast/profile && env NFCXX_BACKEND=$be NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCAST_TIER_PROFILE=1 NFCXX_PROFILE="$out/abort.prof" "$out/driver" abort.lua > "$out/abort.out" 2> "$out/abort.err") ||
     ! grep -q "attempt to divide by zero" "$out/abort.out" || ! "$out/check_any" "$out/abort.prof" | grep -q "sites=1 pairs=1 threads=1"; then
    echo "FAIL $be ast profile abort"; cat "$out/abort.out"; head -5 "$out/abort.err"; "$out/check_any" "$out/abort.prof" 2>&1 | head -3; prof_ok=0; fail=1
  fi
  # Two compiled units in one run: each has its own shared object, and the profile must hold the records of both (one runtime
  # for the process, docs/notes/profiler.md, "Next steps", item 4). tri makes 11 calls, fib(20) makes 21891.
  rm -f "$out/two.prof"
  if ! (cd tests/ast/profile && env NFCXX_BACKEND=$be NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCAST_TIER_PROFILE=1 NFCXX_PROFILE="$out/two.prof" "$out/driver" two.lua > "$out/two.out" 2> "$out/two.err") ||
     ! grep -qx "55" "$out/two.out" || ! grep -qx "6765" "$out/two.out" || ! "$out/check_any" "$out/two.prof" | grep -q "sites=2 pairs=21902 threads=1"; then
    echo "FAIL $be ast profile two units"; cat "$out/two.out"; head -5 "$out/two.err"; "$out/check_any" "$out/two.prof" 2>&1 | head -3; prof_ok=0; fail=1
  fi
  rm -f "$out/plain.prof"
  (cd tests/ast/profile && env NFCXX_BACKEND=$be NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1 NFCXX_PROFILE="$out/plain.prof" "$out/driver" fib.lua > "$out/plain.out") && grep -qx "6765" "$out/plain.out" && test ! -e "$out/plain.prof" ||
    { echo "FAIL $be ast profile: a profile written without NFCAST_TIER_PROFILE"; fail=1; prof_ok=0; }
  [ $prof_ok = 1 ] && echo "ok   $be ast profile: the compiled fib writes 21891 enter/exit pairs, an abandoned run closes its call, two compiled units share one profile, and no profile without NFCAST_TIER_PROFILE"
  # The compute count (docs/notes/profiler.md, "Next steps", item 3): State::stats.node_evals counts the interpreter's node evaluations
  # only in a build with -DNFCAST_COUNT_NODES (the default build compiles the counter out, so its count is 0). This block builds the
  # whole engine and the driver once more with that define, into $out/count, and runs tests/ast/counts/loop.lua there: it makes exactly
  # 28 evaluations (its comment works them out, by phase of the arithmetic node). The default driver must report 0.
  cdir=$out/count; mkdir -p "$cdir"; cobjs=(); cpids=(); cbad=0
  for f in "${srcs[@]}" tests/ast/driver.cpp; do
    o=$cdir/$(basename "$f" .cpp).o; cobjs+=("$o")
    (NFCXX_BACKEND=$be ./nfcxx -c -O2 -DNFCAST_COUNT_NODES -I lib/ast "$f" -o "$o" > "$o.log" 2>&1) & cpids+=($!)
  done
  for p in "${cpids[@]}"; do wait "$p" || cbad=1; done
  cnt_ok=1
  if [ $cbad = 1 ] || ! NFCXX_BACKEND=$be ./nfcxx "${cobjs[@]}" -o "$cdir/driver" > "$cdir/link.log" 2>&1; then
    echo "FAIL $be ast node counts (count build)"; head -10 "$cdir"/*.log | grep -v prelinker; cnt_ok=0; fail=1
  elif ! (cd tests/ast/counts && NFCXX_BACKEND=$be "$cdir/driver" --stats loop.lua > "$out/counts.out" 2> "$out/counts.err") ||
     [ "$(cat "$out/counts.out")" != 15 ] || ! grep -q " node_evals=28$" "$out/counts.err"; then
    echo "FAIL $be ast node counts: count build, loop.lua (expected 15 and node_evals=28)"; cat "$out/counts.out"; tail -1 "$out/counts.err"; cnt_ok=0; fail=1
  fi
  if ! (cd tests/ast/counts && NFCXX_BACKEND=$be "$out/driver" --stats loop.lua > "$out/counts0.out" 2> "$out/counts0.err") ||
     ! grep -q " node_evals=0$" "$out/counts0.err"; then
    echo "FAIL $be ast node counts: the default build counted"; tail -1 "$out/counts0.err"; cnt_ok=0; fail=1
  fi
  [ $cnt_ok = 1 ] && echo "ok   $be ast node counts: tests/ast/counts/loop.lua makes 28 node evaluations in the count build (-DNFCAST_COUNT_NODES), 0 in the default build"
  # Lua 5.4 binary chunks (docs/notes/ast.md, "Bytecode"): the reference Lua dumps each program, and the driver runs the dump.
  if [ -z "${LUA:-}" ] || ! "$LUA" -v 2>&1 | grep -q '^Lua 5\.4\.9\b'; then
    echo "skip $be ast bytecode: set LUA to a Lua 5.4.9 interpreter"
    continue
  fi
  repo=$PWD; bcdir=$out/bc; mkdir -p "$bcdir"; bn=0; bfail=0
  for lua in tests/ast/cases/*.lua tests/ast/bytecode/cases/*.lua; do
    name=$(basename "$lua" .lua); dir=$(dirname "$lua"); chunk=$bcdir/$name.luac
    if ! (cd "$dir" && "$LUA" "$repo/tests/lua54bc/dump.lua" "$name.lua" "$chunk" full); then
      echo "FAIL $be ast bytecode: string.dump of $name"; fail=1; bfail=1; continue
    fi
    for cfg in "" "NFCAST_GC_STRESS=1" "NFCAST_TIER=sync NFCAST_TIER_THRESHOLD=1"; do
      if ! (cd "$dir" && env $cfg NFCXX_BACKEND=$be "$out/driver" "$chunk" > "$bcdir/$name.out" 2> "$bcdir/$name.err") ||
         ! cmp -s "$bcdir/$name.out" "$dir/$name.out"; then
        echo "FAIL $be ast bytecode $name ${cfg:-plain}"; diff "$dir/$name.out" "$bcdir/$name.out" | head -10; head -5 "$bcdir/$name.err"; fail=1; bfail=1
      fi
    done
    bn=$((bn + 1))
  done
  # The stack functions in a bytecode frame, and in a source chunk (which has none).
  if (cd tests/ast/bytecode && "$LUA" "$repo/tests/lua54bc/dump.lua" stack.lua "$bcdir/stack.luac" full) &&
     NFCXX_BACKEND=$be "$out/driver" "$bcdir/stack.luac" > "$bcdir/stack.out" 2> "$bcdir/stack.err" &&
     cmp -s "$bcdir/stack.out" tests/ast/bytecode/stack.out; then :; else
    echo "FAIL $be ast bytecode stack"; diff tests/ast/bytecode/stack.out "$bcdir/stack.out" | head -10; head -5 "$bcdir/stack.err"; fail=1; bfail=1
  fi
  if (cd tests/ast/bytecode && NFCXX_BACKEND=$be "$out/driver" stack_source.lua > "$bcdir/stack_source.out" 2> "$bcdir/stack_source.err") &&
     cmp -s "$bcdir/stack_source.out" tests/ast/bytecode/stack_source.out; then :; else
    echo "FAIL $be ast stack_source"; diff tests/ast/bytecode/stack_source.out "$bcdir/stack_source.out" | head -10; fail=1; bfail=1
  fi
  # The refusal: an opcode outside the subset (TBC) fails the load with its name, before anything runs.
  if (cd tests/ast/bytecode && "$LUA" "$repo/tests/lua54bc/dump.lua" refuse.lua "$bcdir/refuse.luac" full) &&
     ! NFCXX_BACKEND=$be "$out/driver" "$bcdir/refuse.luac" > "$bcdir/refuse.out" 2> "$bcdir/refuse.err" &&
     grep -q "refused: opcode TBC" "$bcdir/refuse.err"; then :; else
    echo "FAIL $be ast bytecode refusal"; head -3 "$bcdir/refuse.err"; fail=1; bfail=1
  fi
  [ $bfail = 0 ] && echo "ok   $be ast bytecode: $bn chunks equal to Lua 5.4.9 (plain, with forced collection, and with the tier at threshold 1); stack access and the refusal checked"
done
exit $fail
