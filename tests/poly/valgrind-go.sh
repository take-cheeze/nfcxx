#!/usr/bin/env bash
# nfcpoly Go under valgrind (memcheck), with tests/poly/valgrind-go.supp. By hand, not in CI: about 5-8 minutes per back end.
# valgrind cannot follow the Go runtime (goroutine stacks, the collector), so the suppression file drops the errors whose
# innermost frame is in libnfcgo.so, and the host functions' accesses to Go-owned memory; what is left is a leak of a block that C
# or C++ code allocated (the bridge's tables, cgo's C.malloc replies), an invalid free, and an uninitialised read in the host code.
# AddressSanitizer (tests/poly/asan-go.sh) is the stronger tool for the same code; use this one as a second opinion.
#   NFCXX_BACKEND=gcc|qbe   (default gcc)    POLY_GO_DIR=DIR   the library (default build/poly-go)
cd "$(dirname "$0")/../.."
be=${NFCXX_BACKEND:-gcc}
command -v valgrind >/dev/null || { echo "SKIP valgrind go: valgrind is not installed"; exit 0; }
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
NFCXX_BACKEND=$be POLY_LANGS=go POLY_OUT=$out tests/poly/run.sh || exit 1
log=$out/valgrind.log
(cd "$out" && valgrind --error-limit=no --leak-check=full --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect \
  --suppressions="$OLDPWD/tests/poly/valgrind-go.supp" --error-exitcode=9 --num-callers=30 "$out/host-$be") >"$log" 2>&1
rc=$?
summary=$(grep 'ERROR SUMMARY' "$log" | sed 's/^==[0-9]*== //')
if [ $rc = 0 ] && grep -q 'checks passed' "$log"; then
  echo "ok   $be valgrind go: $(grep 'checks passed' "$log" | tail -1); $summary"
else
  echo "FAIL $be valgrind go (exit $rc): $summary"; grep -v '^-- ' "$log" | cut -c1-200 | head -60; exit 1
fi
