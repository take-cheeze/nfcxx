#!/usr/bin/env bash
# nfcpoly Go: run the Go-only host binary N times per back end (default 200) to catch flaky checks, in particular those of the
# exact collector. The binary is built once per back end by tests/poly/run.sh (POLY_LANGS=go POLY_OUT=DIR).
#   tests/poly/stress-go.sh [N]      env: NFCXX_BACKEND="qbe gcc"  JOBS=4 (parallel runs; more load makes scheduling noisier)
#                                    NFC_GO_REPS=N repeats each collector scenario N times inside every run (host.cpp)
#                                    POLY_GO_DIR=DIR a private copy of the library (build/ may be shared with other checkouts)
cd "$(dirname "$0")/../.."
n=${1:-200}; backends=${NFCXX_BACKEND:-"qbe gcc"}; jobs=${JOBS:-4}
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
POLY_LANGS=go POLY_OUT=$out tests/poly/run.sh || exit 1
rc=0
for be in $backends; do
  seq 1 "$n" | xargs -P "$jobs" -I{} sh -c "'$out/host-$be' >'$out/$be.{}.log' 2>&1 || echo failed >'$out/$be.{}.fail'"
  bad=$(ls "$out" | grep -c "^$be\..*\.fail$")
  echo "stress $be go: $n runs, $bad failed"
  if [ "$bad" != 0 ]; then
    rc=1; f=$(ls "$out" | grep "^$be\..*\.fail$" | head -3)
    for x in $f; do grep -v '^ok\|^--' "$out/${x%.fail}.log" | head -8; done
  fi
done
exit $rc
