#!/usr/bin/env bash
# CI check of Path B on hosted programs (docs/notes/pathb-hosted.md): the hosted probes of tests/pathb-qbe/cases
# (cstdio, cstdlib/cstring, new, stdexcept, string, vector, map, unordered_*, algorithm, structs by value, varargs),
# then the driver in Path B mode (NFCXX_PATH=b): every tests/cases program and tinyxml2 (tests/realworld/run.sh sources,
# pinned; skipped when they cannot be fetched). Needs the Path B harness (PATHB_CPFE, PATHB_BASE; scripts/setup-pathb.sh),
# QBE and EDG's runtime library like tests/pathb-qbe/run.sh. Exit 2 when those are missing.
cd "$(dirname "$0")/../.."
root=$PWD
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] && [ -x "$root/build/qbe/qbe" ] || { echo "hosted: no Path B harness or QBE (see tests/pathb-qbe/run.sh)" >&2; exit 2; }
fail=0
PATHB_QBE_ONLY='cases/(hosted_|abi_|vararg_|base_null)|multi/abi_c' tests/pathb-qbe/run.sh | tail -3 || fail=1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
NFCXX_PATH=b tests/run.sh | sed 's/^/pathb-driver: /' > "$tmp/run.out"; grep -q FAIL "$tmp/run.out" && { fail=1; grep FAIL "$tmp/run.out"; } || echo "pathb-driver: tests/cases ok"
src=$root/build/realworld/tinyxml2
if [ -f "$src/tinyxml2.cpp" ] || { tests/realworld/run.sh >/dev/null 2>&1; [ -f "$src/tinyxml2.cpp" ]; }; then
  if NFCXX_PATH=b ./nfcxx -I"$src" tests/realworld/tinyxml2_main.cpp "$src/tinyxml2.cpp" -o "$tmp/tx" 2> "$tmp/tx.err"; then
    "$tmp/tx"; got=$?
    [ $got = 12 ] && echo "ok   tinyxml2 through Path B" || { echo "FAIL tinyxml2 through Path B: want 12 got $got"; fail=1; }
  else echo "FAIL tinyxml2 through Path B (build)"; head -3 "$tmp/tx.err"; fail=1; fi
else echo "skip tinyxml2: sources not available"; fi
exit $fail
