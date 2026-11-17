#!/bin/bash
# scripts/nfcxx-time-log.rb plan must set NFCXX_TIME_LOG as the driver's line does (the bash abs_path, verbatim below), for each
# shape of path: a bare name, a relative directory, a missing directory, an absolute path, a path through a symbolic link, and an
# empty time log (no export).   bash tests/driver-time-log/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/real/sub" && ln -s "$t/real" "$t/link"
abs_path() {   # the driver's function, verbatim
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if (cd "$d" 2>/dev/null); then (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  else printf '%s\n' "$1"; fi
}
pass=0; fail=0
cd "$t/real"
for time_log in log.txt sub/x.log nodir/x.log "$t/real/sub/y.log" "$t/link/z.log" "$t/link/sub/../w.log" "" "./q.log"; do
  if [ -z "$time_log" ]; then want=""; else
    # the driver's line: [ -z "$time_log" ] || export NFCXX_TIME_LOG=$(abs_path "$time_log")
    want="export NFCXX_TIME_LOG=$(abs_path "$time_log")"; fi
  got=$(ruby "$repo/scripts/nfcxx-time-log.rb" plan time_log="$time_log")
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL [$time_log]: bash [$want] ruby [$got]"; fi
done
echo "driver-time-log: $pass passed, $fail failed"
[ $fail = 0 ]
