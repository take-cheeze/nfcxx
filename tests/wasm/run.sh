#!/usr/bin/env bash
# Path B wasm emitter: each tests/wasm/*.cpp is lowered to IR (scripts/pathb-dump --ir), emitted as a wasm module
# (scripts/pathb-wasm-emit.rb), and run under node (tests/wasm/host.cjs). A test marks its expected result with
# "// EXPECT: N" (main's return value), "// TRAP" (main traps), or "// REFUSE: TEXT" (the emitter refuses the module with
# TEXT on stderr, exit status 3). The expected values of the EXPECT tests are the results of the host g++ at -O0, except
# calls.cpp, whose import returns its argument plus one.
# NFCXX_WASM_ASAN=1 emits every module in the AddressSanitizer-style mode (--asan). Then a test with "// ASAN: KIND"
# must report that violation (the host prints "asan: KIND"), and the EXPECT tests must still give their result. Without
# the variable the ASAN tests are skipped: their modules are not checked without the mode.
# NFCXX_WASM_EMSCRIPTEN=1 emits every module with --emscripten (tests/wasm/emscripten.cjs checks its exports and
# layout), and the tests must still give their results. NFCXX_WASM_EMSCRIPTEN=import adds --emscripten-import-memory
# (the memory is imported as env.memory; the host provides it). Neither is combined with NFCXX_WASM_ASAN.
# Skipped, not failed, without node (set NODE to a binary) or without the Path B harness (scripts/setup-pathb.sh).
cd "$(dirname "$0")/../.."
root=$PWD; dir=$root/tests/wasm
node=${NODE:-$(command -v node || true)}
[ -n "$node" ] || { echo "SKIP tests/wasm: no node"; exit 0; }
asan=0; emscripten=0; mode_args=(); mode=plain
if [ "${NFCXX_WASM_ASAN:-}" = 1 ]; then asan=1; mode_args=(--asan); mode=asan; fi
if [ "${NFCXX_WASM_EMSCRIPTEN:-}" = 1 ]; then emscripten=1; mode_args=(--emscripten); mode=emscripten; fi
if [ "${NFCXX_WASM_EMSCRIPTEN:-}" = import ]; then emscripten=1; mode_args=(--emscripten --emscripten-import-memory); mode=emscripten-import; fi
[ $asan = 1 ] && [ $emscripten = 1 ] && { echo "tests/wasm: NFCXX_WASM_ASAN and NFCXX_WASM_EMSCRIPTEN are not combined" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skip=0
for f in "$dir"/*.cpp; do
  n=$(basename "$f" .cpp)
  kind=$(sed -n 's|^// ASAN: *\([a-z-]*\).*|\1|p' "$f" | head -1)
  if [ -n "$kind" ] && [ $asan = 0 ]; then
    echo "skip $n (// ASAN: $kind: needs NFCXX_WASM_ASAN=1)"; skip=$((skip + 1)); continue
  fi
  want=$(sed -n 's|^// EXPECT: *\([0-9-]*\).*|\1|p' "$f" | head -1)
  trap_want=$(grep -c '^// TRAP' "$f")
  refuse=$(sed -n 's|^// REFUSE: *||p' "$f" | head -1)
  if ! "$root/scripts/pathb-dump" --ir "$f" > "$tmp/$n.ir" 2> "$tmp/$n.front"; then
    echo "FAIL $n: front end: $(head -1 "$tmp/$n.front")"; fail=$((fail + 1)); continue
  fi
  if [ -n "$refuse" ]; then
    if "$root/scripts/mrb" "$root/scripts/pathb-wasm-emit.rb" "${mode_args[@]}" "$tmp/$n.ir" > "$tmp/$n.wasm" 2> "$tmp/$n.err"; then
      echo "FAIL $n: emitted a module, expected a refusal"; fail=$((fail + 1))
    elif grep -qF "refused: $refuse" "$tmp/$n.err" || grep -qF "$refuse" "$tmp/$n.err"; then
      echo "ok   $n (refused: $(head -1 "$tmp/$n.err"))"; pass=$((pass + 1))
    else
      echo "FAIL $n: refusal text was: $(head -1 "$tmp/$n.err")"; fail=$((fail + 1))
    fi
    continue
  fi
  if ! "$root/scripts/mrb" "$root/scripts/pathb-wasm-emit.rb" "${mode_args[@]}" "$tmp/$n.ir" > "$tmp/$n.wasm" 2> "$tmp/$n.err"; then
    echo "FAIL $n: emitter: $(head -1 "$tmp/$n.err")"; fail=$((fail + 1)); continue
  fi
  if [ $emscripten = 1 ] && ! "$node" "$dir/emscripten.cjs" "$tmp/$n.wasm" > "$tmp/$n.emcc" 2>&1; then
    echo "FAIL $n: $(head -1 "$tmp/$n.emcc")"; fail=$((fail + 1)); continue
  fi
  got=$("$node" "$dir/host.cjs" "$tmp/$n.wasm" 2>&1 | tail -1)
  if [ -n "$kind" ]; then
    if [ "$got" = "asan: $kind" ]; then echo "ok   $n (asan: $kind)"; pass=$((pass + 1))
    else echo "FAIL $n: want asan: $kind, got $got"; fail=$((fail + 1)); fi
  elif [ "$trap_want" -gt 0 ]; then
    if [ "$got" = trap ]; then echo "ok   $n (trap)"; pass=$((pass + 1))
    else echo "FAIL $n: want a trap, got $got"; fail=$((fail + 1)); fi
  elif [ "$got" = "$want" ]; then echo "ok   $n ($got)"; pass=$((pass + 1))
  else echo "FAIL $n: want $want, got $got"; fail=$((fail + 1)); fi
done
echo "tests/wasm ($mode): $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
