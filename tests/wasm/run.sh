#!/usr/bin/env bash
# Path B wasm emitter: each tests/wasm/*.cpp is lowered to IR (scripts/pathb-dump --ir), emitted as a wasm module
# (scripts/pathb-wasm-emit.rb), and run under node (tests/wasm/host.cjs). A test marks its expected result with
# "// EXPECT: N" (main's return value), "// TRAP" (main traps), or "// REFUSE: TEXT" (the emitter refuses the module with
# TEXT on stderr, exit status 3). The expected values of the EXPECT tests are the results of the host g++ at -O0, except
# calls.cpp, whose import returns its argument plus one.
# Skipped, not failed, without node (set NODE to a binary) or without the Path B harness (scripts/setup-pathb.sh).
cd "$(dirname "$0")/../.."
root=$PWD; dir=$root/tests/wasm
node=${NODE:-$(command -v node || true)}
[ -n "$node" ] || { echo "SKIP tests/wasm: no node"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
for f in "$dir"/*.cpp; do
  n=$(basename "$f" .cpp)
  want=$(sed -n 's|^// EXPECT: *\([0-9-]*\).*|\1|p' "$f" | head -1)
  trap_want=$(grep -c '^// TRAP' "$f")
  refuse=$(sed -n 's|^// REFUSE: *||p' "$f" | head -1)
  if ! "$root/scripts/pathb-dump" --ir "$f" > "$tmp/$n.ir" 2> "$tmp/$n.front"; then
    echo "FAIL $n: front end: $(head -1 "$tmp/$n.front")"; fail=$((fail + 1)); continue
  fi
  if [ -n "$refuse" ]; then
    if "$root/scripts/mrb" "$root/scripts/pathb-wasm-emit.rb" "$tmp/$n.ir" > "$tmp/$n.wasm" 2> "$tmp/$n.err"; then
      echo "FAIL $n: emitted a module, expected a refusal"; fail=$((fail + 1))
    elif grep -qF "refused: $refuse" "$tmp/$n.err" || grep -qF "$refuse" "$tmp/$n.err"; then
      echo "ok   $n (refused: $(head -1 "$tmp/$n.err"))"; pass=$((pass + 1))
    else
      echo "FAIL $n: refusal text was: $(head -1 "$tmp/$n.err")"; fail=$((fail + 1))
    fi
    continue
  fi
  if ! "$root/scripts/mrb" "$root/scripts/pathb-wasm-emit.rb" "$tmp/$n.ir" > "$tmp/$n.wasm" 2> "$tmp/$n.err"; then
    echo "FAIL $n: emitter: $(head -1 "$tmp/$n.err")"; fail=$((fail + 1)); continue
  fi
  got=$("$node" "$dir/host.cjs" "$tmp/$n.wasm" 2>&1 | tail -1)
  if [ "$trap_want" -gt 0 ]; then
    if [ "$got" = trap ]; then echo "ok   $n (trap)"; pass=$((pass + 1))
    else echo "FAIL $n: want a trap, got $got"; fail=$((fail + 1)); fi
  elif [ "$got" = "$want" ]; then echo "ok   $n ($got)"; pass=$((pass + 1))
  else echo "FAIL $n: want $want, got $got"; fail=$((fail + 1)); fi
done
echo "tests/wasm: $pass passed, $fail failed"
[ $fail -eq 0 ]
