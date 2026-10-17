#!/bin/sh
# Integration tests: builds each testbed program with swiftfe and compares its
# output with the output of the real Swift compiler (programs/NAME.expected).
# A program that swiftfe cannot compile is reported with its diagnostic.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
bin="$root/.build/release/swiftfe"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
for src in "$dir"/programs/*.swift; do
  name=$(basename "$src" .swift)
  if ! out=$("$bin" build "$src" -o "$tmp/$name" 2>&1); then
    fail=$((fail + 1))
    echo "FAIL $name: $(echo "$out" | head -n 1)"
    continue
  fi
  actual=$(sh -c "\"$tmp/$name\"" 2>/dev/null)
  if [ "$actual" != "$(cat "$dir/programs/$name.expected")" ]; then
    fail=$((fail + 1))
    echo "FAIL $name: output differs from swiftc"
    continue
  fi
  # The emitted C must also be clean under AddressSanitizer, LeakSanitizer and UBSan.
  "$bin" emit-c "$src" > "$tmp/$name.c"
  if ! cc -std=c11 -g -fsanitize=address,undefined -Wall -Werror -Wno-unused-function \
      -Wno-unused-variable -Wno-unused-but-set-variable -o "$tmp/$name.san" "$tmp/$name.c" 2>"$tmp/$name.cc"; then
    fail=$((fail + 1))
    echo "FAIL $name: sanitized build failed: $(head -n 1 "$tmp/$name.cc")"
    continue
  fi
  if ! sh -c "\"$tmp/$name.san\"" >/dev/null 2>"$tmp/$name.serr" || grep -q 'ERROR\|runtime error\|leak' "$tmp/$name.serr"; then
    fail=$((fail + 1))
    echo "FAIL $name: sanitizer reported a problem"
    continue
  fi
  pass=$((pass + 1))
done
echo "integration: $pass passed, $fail failed (sanitizers on every program)"
[ $fail -eq 0 ]
