#!/bin/bash
# The Ruby driver's exit status with --trace is the bash driver's: a failing build exits with the bash's status (not the
# trace's 0), a successful one exits 0, and a refusal exits with the refusal's status. Each case runs the bash driver and the
# Ruby driver (scripts/nfcxx.rb) on the same arguments in a scratch directory and compares the statuses.
#   bash tests/driver-trace-status/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
printf 'int main(){}\n' > "$work/m.cpp"
cd "$work" || exit 1

# case NAME ARGS...: the statuses of the bash driver and the Ruby driver on ARGS must be equal (and both reported)
case_() {
  local name=$1; shift
  local b r
  "$repo/nfcxx" "$@" >/dev/null 2>&1; b=$?
  ruby "$repo/scripts/nfcxx.rb" "$@" >/dev/null 2>&1; r=$?
  if [ "$b" = "$r" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $name: bash $b, ruby $r"; fi
}

case_ "failing build with --trace (the status of the oracle, not the trace)" --backend=gcc -fsanitize=bogus m.cpp --trace="$work/t1.tr"
case_ "failing build without --trace" --backend=gcc -fsanitize=bogus m.cpp
case_ "successful build with --trace" --backend=gcc m.cpp -o p --trace="$work/t2.tr"
case_ "successful build without --trace" --backend=gcc m.cpp -o p

echo "driver-trace-status: $pass passed, $fail failed"
[ "$fail" = 0 ]
