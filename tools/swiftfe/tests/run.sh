#!/bin/sh
# M1 end-to-end tests. For each tests/cases/NAME.swift:
#   NAME.expected  stdout of the built program must match exactly
#   NAME.trap      the built program must exit nonzero (a Swift runtime trap)
#   NAME.error     compilation must fail and print this diagnostic line
set -u

dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/.." && pwd)
bin="$root/.build/release/swiftfe"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
clean=0
report() {
  if [ "$1" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $2: $3"; fi
}
# Same as report, for the sanitizer pass, which is counted separately.
sreport() {
  if [ "$1" = ok ]; then clean=$((clean + 1)); else fail=$((fail + 1)); echo "FAIL sanitizer $2: $3"; fi
}

for src in "$dir"/cases/*.swift; do
  name=$(basename "$src" .swift)
  cases="$dir/cases"

  if [ -f "$cases/$name.error" ]; then
    out=$("$bin" build "$src" -o "$tmp/$name" 2>&1)
    status=$?
    want=$(cat "$cases/$name.error")
    if [ $status -ne 0 ] && echo "$out" | grep -qF "$want"; then
      report ok "$name" ""
    else
      report bad "$name" "expected diagnostic '$want', got: $out"
    fi
    continue
  fi

  if ! out=$("$bin" build "$src" -o "$tmp/$name" 2>&1); then
    report bad "$name" "build failed: $out"
    continue
  fi

  # Run in a child shell so a trap's "Aborted" notice does not reach our output.
  actual=$(sh -c "\"$tmp/$name\"" 2>"$tmp/$name.stderr")
  status=$?
  if [ -f "$cases/$name.trap" ]; then
    if [ $status -ne 0 ] && [ "$actual" = "$(cat "$cases/$name.expected")" ]; then
      report ok "$name" ""
    else
      report bad "$name" "expected a trap after output, status $status, output: $actual"
    fi
  elif [ "$actual" = "$(cat "$cases/$name.expected")" ] && [ $status -eq 0 ]; then
    report ok "$name" ""
  else
    report bad "$name" "output mismatch (status $status): $actual"
  fi
done

# Sanitizer pass. The C that swiftfe emits for each program that should run is
# built with AddressSanitizer, LeakSanitizer and UBSan. It must print the
# expected output and exit the same way as the ordinary build: 0, or nonzero
# for a trap case. Any leak or undefined behaviour makes the run fail.
for src in "$dir"/cases/*.swift; do
  name=$(basename "$src" .swift)
  cases="$dir/cases"
  [ -f "$cases/$name.error" ] && continue

  if ! "$bin" emit-c "$src" > "$tmp/$name.c"; then
    sreport bad "$name" "emit-c failed under the sanitizer pass"
    continue
  fi
  if ! cc -std=c11 -fsanitize=address,leak,undefined -fno-sanitize-recover=all -o "$tmp/$name.san" "$tmp/$name.c" 2>"$tmp/$name.cc"; then
    sreport bad "$name" "sanitized build failed: $(cat "$tmp/$name.cc")"
    continue
  fi
  actual=$(sh -c "\"$tmp/$name.san\"" 2>"$tmp/$name.san.err")
  status=$?
  if [ -f "$cases/$name.trap" ]; then
    want_status=nonzero
  else
    want_status=zero
  fi
  if [ "$actual" != "$(cat "$cases/$name.expected")" ]; then
    sreport bad "$name" "sanitized output mismatch: $(cat "$tmp/$name.san.err")"
  elif [ "$want_status" = zero ] && [ $status -ne 0 ]; then
    sreport bad "$name" "sanitized run failed with status $status: $(cat "$tmp/$name.san.err")"
  elif [ "$want_status" = nonzero ] && [ $status -eq 0 ]; then
    sreport bad "$name" "sanitized run should trap but exited 0"
  else
    sreport ok "$name" ""
  fi
done

echo "$pass passed, $fail failed (sanitizer: $clean clean)"
[ $fail -eq 0 ]
