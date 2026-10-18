#!/usr/bin/env bash
# Regression: scripts/pathb-dump forwards diagnostic options (-W*, --diag_*) to cpfe unchanged, and still runs realpath
# on the file arguments. A fake cpfe (PATHB_CPFE) records its argv; the test checks that -Wno-narrowing and
# --diag_warning=narrowing_conversion reach it, and that the file is passed as an absolute path. No real front end runs.
set -uo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$tmp" > "$tmp/cpfe"
chmod +x "$tmp/cpfe"
printf 'int x;\n' > "$tmp/t.cpp"
fail=0
if ! PATHB_CPFE="$tmp/cpfe" PATHB_BASE="$tmp" "$root/scripts/pathb-dump" --ir -Wno-narrowing --diag_warning=narrowing_conversion "$tmp/t.cpp" > /dev/null 2>"$tmp/err"; then
  echo "FAIL pathb-dump rejected diagnostic options"; cat "$tmp/err"; exit 1
fi
for want in -Wno-narrowing --diag_warning=narrowing_conversion "$tmp/t.cpp"; do
  if grep -qxF -- "$want" "$tmp/argv"; then :; else echo "FAIL cpfe did not receive: $want"; fail=1; fi
done
[ $fail = 0 ] && echo "ok   diag options reach cpfe"
exit $fail
