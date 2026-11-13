#!/usr/bin/env bash
# Class results EDG lowers into a hidden first parameter, across translation units (AArch64: x8 in the C convention; see
# scripts/pathb-ssa-qbe.rb, hidden-result). a.cpp calls the results of lib.cpp, so each call crosses a unit boundary; the
# program is built by the default driver (Path B) and by gcc, and both must exit 0 (the EXPECT line of a.cpp).
#   NFCXX_BACKEND=pathb|gcc   (default: the driver's own choice, then gcc)
cd "$(dirname "$0")/../.."
dir=tests/hidden-result
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
want=$(sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$dir/a.cpp" | head -1)
for be in ${NFCXX_BACKEND:-default gcc}; do
  if [ "$be" = default ]; then unset NFCXX_BACKEND; else export NFCXX_BACKEND=$be; fi
  if ! ./nfcxx "$dir/a.cpp" "$dir/lib.cpp" -o "$tmp/t-$be" 2>"$tmp/err-$be"; then
    echo "FAIL $be: compile"; head -10 "$tmp/err-$be"; fail=1; continue
  fi
  if [ "$be" = default ] && grep -q "building the program with the gcc backend" "$tmp/err-$be"; then echo "FAIL default: Path B refused a unit and the gcc fallback built it"; fail=1; fi
  "$tmp/t-$be" >"$tmp/out-$be" 2>&1; got=$?
  if [ "$got" -eq "$want" ]; then echo "ok   $be ($(cat "$tmp/out-$be"))"; else echo "FAIL $be: want $want got $got"; cat "$tmp/out-$be"; fail=1; fi
done
unset NFCXX_BACKEND
exit $fail
