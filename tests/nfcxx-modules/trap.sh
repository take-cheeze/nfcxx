#!/bin/bash
# The EXIT traps of a build with C++ modules (mod_build_program in nfcxx). The build exits with its own status, and the traps
# set before it must still run: cu_prepare's removal of the .cu copy and trace_begin's closing of the trace file (NFCXX_TRACE).
# The module build used to clear them (trap - EXIT). Two cases, each with a private TMPDIR so its leftovers can be seen:
#   - a module and a plain .cpp importing it: builds (status 0); the trace file ends with "]" (closed).
#   - a module and a .cu importing it: the copy's directory (cu_prepare's temporary directory) is gone afterwards, and the trace
#     file ends with "]", and the program runs and returns 0 (the .cu name is not passed to the sub-compiles as a second source).
# The build is the real driver, so it needs the built EDG front end (build/edg/bin/eccp, scripts/setup-edg.sh); the test is
# skipped when that is absent.
#   bash tests/nfcxx-modules/trap.sh [ROOT]     (ROOT: a repository root, default this one)
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
root=${1:-$(cd "$here/../.." && pwd -P)}
if [ ! -x "$root/build/edg/bin/eccp" ]; then echo "trap: skipped (no build/edg/bin/eccp; scripts/setup-edg.sh)"; exit 0; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
check() {  # check NAME CONDITION-RESULT(0/1) DETAIL
  if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: $3"; fi
}
printf 'export module m;\nexport int f() { return 41; }\n' > "$work/m.cppm"
printf 'import m;\nint main() { return f() == 41 ? 0 : 1; }\n' > "$work/main.cpp"
cp "$work/main.cpp" "$work/main.cu"
# trace_closed FILE: 0 when the trace file is a finished JSON array
trace_closed() { [ "$(tail -c 2 "$1" | tr -d '\n')" = "]" ]; }

# 1. a module and a .cpp: the build succeeds and the trace is closed
d=$work/plain; mkdir -p "$d/tmp" "$d/src"; cp "$work/m.cppm" "$work/main.cpp" "$d/src/"
(cd "$d/src" && env -u CUDA_HOME TMPDIR="$d/tmp" NFCXX_TRACE="$d/trace.json" "$root/nfcxx" m.cppm main.cpp -o "$d/prog") >"$d/out" 2>&1; rc=$?
check "plain build status" "$( [ $rc = 0 ] && echo 0 || echo 1 )" "status $rc: $(head -3 "$d/out")"
check "plain build: trace closed" "$(trace_closed "$d/trace.json"; echo $?)" "trace does not end with ]"
check "plain build: no leftovers" "$( [ -z "$(ls -A "$d/tmp")" ] && echo 0 || echo 1 )" "$(ls -A "$d/tmp" | tr '\n' ' ')"
[ "$rc" = 0 ] && check "plain build runs" "$("$d/prog" >/dev/null; echo $?)" "prog did not return 0"

# 2. a module and a .cu: cu_prepare's directory is removed and the trace is closed
d=$work/cu; mkdir -p "$d/tmp" "$d/src"; cp "$work/m.cppm" "$work/main.cu" "$d/src/"
(cd "$d/src" && env -u CUDA_HOME TMPDIR="$d/tmp" NFCXX_TRACE="$d/trace.json" "$root/nfcxx" m.cppm main.cu -o "$d/prog") >"$d/out" 2>&1; rc=$?
check "cu build: status 0" "$( [ $rc = 0 ] && echo 0 || echo 1 )" "status $rc: $(head -3 "$d/out")"
check "cu build: the program returns 0" "$( "$d/prog" >/dev/null 2>&1 && echo 0 || echo 1 )" "program did not return 0"
check "cu build: no leftovers in TMPDIR" "$( [ -z "$(ls -A "$d/tmp")" ] && echo 0 || echo 1 )" "left: $(ls -A "$d/tmp" | tr '\n' ' ')"
check "cu build: trace closed" "$(trace_closed "$d/trace.json"; echo $?)" "trace does not end with ]"

echo "trap: $pass passed, $fail failed"
[ $fail = 0 ]
