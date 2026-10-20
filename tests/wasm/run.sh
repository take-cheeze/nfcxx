#!/usr/bin/env bash
# Path B wasm emitter: each tests/wasm/*.cpp is lowered to IR (scripts/pathb-dump --ir), emitted as a wasm module
# (scripts/pathb-wasm-emit.rb), and run under node (tests/wasm/host.cjs). A test marks its expected result with
# "// EXPECT: N" (main's return value), "// TRAP" (main traps), or "// REFUSE: TEXT" (the emitter refuses the module with
# TEXT on stderr, exit status 3). The expected values of the EXPECT tests are the results of the host g++ at -O0, except
# calls.cpp, whose import returns its argument plus one. A test whose result depends on the width of long has "// EXPECT-ILP32: N"
# too: under the emscripten modes (ILP32) its result is N, the g++ -m32 result.
# NFCXX_WASM_ASAN=1 emits every module in the AddressSanitizer-style mode (--asan). Then a test with "// ASAN: KIND"
# must report that violation (the host prints "asan: KIND"), and the EXPECT tests must still give their result. Without
# the variable the ASAN tests are skipped: their modules are not checked without the mode. A test with "// ASAN-EXPECT: N"
# is a clean program that needs the mode (its malloc and free are the module's own only under --asan): it runs under the
# mode, which must give N, and is skipped otherwise.
# NFCXX_WASM_EMSCRIPTEN=1 emits every module with --emscripten from the ILP32 IR (pathb-dump --target linux_riscv32, the
# data model of Emscripten's wasm32: pointers are i32). tests/wasm/emscripten.cjs checks its exports and layout, and the
# tests must still give their results. NFCXX_WASM_EMSCRIPTEN=import adds --emscripten-import-memory (the memory is
# imported as env.memory; the host provides it). Neither is combined with NFCXX_WASM_ASAN.
# NFCXX_WASM_MEMORY64=1 emits every module with --memory64 (the LP64 IR, with a 64-bit memory: addresses are i64). The
# tests must give the same results. A test with "// MEMORY64-TRAP" traps only under the mode (its address is outside the
# 32-bit memory, which the default module wraps), so it runs under the mode and is skipped otherwise. The ASan and the
# Emscripten modes are not combined with it.
# Skipped, not failed, without node (set NODE to a binary) or without the Path B harness (scripts/setup-pathb.sh).
cd "$(dirname "$0")/../.."
root=$PWD; dir=$root/tests/wasm
node=${NODE:-$(command -v node || true)}
[ -n "$node" ] || { echo "SKIP tests/wasm: no node"; exit 0; }
asan=0; emscripten=0; mode_args=(); mode=plain
if [ "${NFCXX_WASM_ASAN:-}" = 1 ]; then asan=1; mode_args=(--asan); mode=asan; fi
ir_args=(--ir)                             # the front end's mode: LP64 by default
memory64=0
if [ "${NFCXX_WASM_MEMORY64:-}" = 1 ]; then memory64=1; mode_args=(--memory64); mode=memory64; fi
if [ "${NFCXX_WASM_EMSCRIPTEN:-}" = 1 ]; then emscripten=1; mode_args=(--emscripten); mode=emscripten; fi
if [ "${NFCXX_WASM_EMSCRIPTEN:-}" = import ]; then emscripten=1; mode_args=(--emscripten --emscripten-import-memory); mode=emscripten-import; fi
[ $emscripten = 1 ] && ir_args=(--ir --freestanding --target linux_riscv32)   # ILP32, as wasm32
[ $asan = 1 ] && [ $emscripten = 1 ] && { echo "tests/wasm: NFCXX_WASM_ASAN and NFCXX_WASM_EMSCRIPTEN are not combined" >&2; exit 2; }
[ $memory64 = 1 ] && [ $asan = 1 -o $emscripten = 1 ] && { echo "tests/wasm: NFCXX_WASM_MEMORY64 is not combined with ASAN or EMSCRIPTEN" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skip=0
for f in "$dir"/*.cpp; do
  n=$(basename "$f" .cpp)
  kind=$(sed -n 's|^// ASAN: *\([a-z-]*\).*|\1|p' "$f" | head -1)
  if [ -n "$kind" ] && [ $asan = 0 ]; then
    echo "skip $n (// ASAN: $kind: needs NFCXX_WASM_ASAN=1)"; skip=$((skip + 1)); continue
  fi
  want=$(sed -n 's|^// EXPECT: *\([0-9-]*\).*|\1|p' "$f" | head -1)
  # under ILP32 (the emscripten modes) a test that depends on the width of long has its own expectation: g++ -m32 gives it
  want32=$(sed -n 's|^// EXPECT-ILP32: *\([0-9-]*\).*|\1|p' "$f" | head -1)
  if [ $emscripten = 1 ] && [ -n "$want32" ]; then want=$want32; fi
  aexpect=$(sed -n 's|^// ASAN-EXPECT: *\([0-9-]*\).*|\1|p' "$f" | head -1)
  if [ -n "$aexpect" ]; then
    if [ $asan = 0 ]; then echo "skip $n (// ASAN-EXPECT: needs NFCXX_WASM_ASAN=1)"; skip=$((skip + 1)); continue; fi
    want=$aexpect
  fi
  trap_want=$(grep -c '^// TRAP' "$f")
  mem64_trap=$(grep -c '^// MEMORY64-TRAP' "$f")
  if [ "$mem64_trap" -gt 0 ]; then
    if [ $memory64 = 0 ]; then echo "skip $n (// MEMORY64-TRAP: needs NFCXX_WASM_MEMORY64=1)"; skip=$((skip + 1)); continue; fi
    trap_want=$((trap_want + 1))
  fi
  refuse=$(sed -n 's|^// REFUSE: *||p' "$f" | head -1)
  if ! "$root/scripts/pathb-dump" "${ir_args[@]}" "$f" > "$tmp/$n.ir" 2> "$tmp/$n.front"; then
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
