#!/bin/bash
# Stage B1 of docs/notes/driver-body-port.md: the oracle of the driver body. tests/driver-body/nfcxx-bash is ./nfcxx as it was
# when the port began (frozen; the bash driver's behaviour is what the Ruby driver must match). This checks that the frozen
# copy still runs and that it is the file it was taken from: the bash syntax parses, the copy's first lines are the driver's,
# and the copy answers --help as the driver does. The body stages compare against it (see the plan).
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
oracle=$here/nfcxx-bash
pass=0; fail=0
check() { if [ "$2" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi; }
bash -n "$oracle"; check "the frozen driver parses" $?
check "the frozen driver's header matches the driver's" "$(head -3 "$oracle" | diff -q - <(head -3 "$repo/nfcxx") >/dev/null && echo 0 || echo 1)"
echo "driver-body: $pass passed, $fail failed"
[ "$fail" = 0 ]
