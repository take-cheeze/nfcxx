#!/bin/bash
# The driver's temporary directories of the front-end and Path B routes are removed when the driver exits: the output
# directory of --emit-c (tmp), the Path B objects of a link (ptmp), on success and on failure. The C++ routes need the EDG
# build (scripts/setup-edg.sh) and the Path B build; the gcc route is in tests/driver-ctmp-cleanup.
#   bash tests/driver-tmp-cleanup/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main() { return 0; }\n' > m.cpp
printf 'int main() { return 1 +; }\n' > bad.cpp
n=0

# run NAME COMMAND...: the command with TMPDIR set to its own directory; no directory may be left behind
run() {
  local name=$1; shift
  n=$((n + 1)); local tdir="$work/t$n"; mkdir "$tdir"
  env TMPDIR="$tdir" "$@" >/dev/null 2>&1; st=$?
  local left; left=$(ls -A "$tdir" | grep -c '^tmp\.' || true)
  LAST_STATUS=$st
  if [ "$left" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name leaves $left directory(ies) (status $st)"; fi
}

run "--emit-c" "$repo/nfcxx" --emit-c m.cpp
run "Path B link" env NFCXX_BACKEND=pathb "$repo/nfcxx" -o pm m.cpp
run "default link" "$repo/nfcxx" -o pm2 m.cpp
run "failing link (Path B)" env NFCXX_BACKEND=pathb "$repo/nfcxx" -o pm3 bad.cpp
run "Path B -c" env NFCXX_BACKEND=pathb "$repo/nfcxx" -c m.cpp -o m.o

echo "driver-tmp-cleanup: $pass passed, $fail failed"
[ $fail = 0 ]
