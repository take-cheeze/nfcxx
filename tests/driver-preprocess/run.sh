#!/bin/bash
# The -E route of the driver: the host C++ compiler preprocesses (the body's "if [ $preprocess = 1 ]" block). The expected output
# (stdout, the -o file, the driver's own stderr lines, and the status of each case) is golden/, recorded from the driver before the
# route's command line moved to scripts/nfcxx-preprocess.rb. Each case runs the driver through scripts/nfcxx.rb.
#   bash tests/driver-preprocess/run.sh            checks the cases against golden/
#   bash tests/driver-preprocess/run.sh --record   writes golden/ from the current driver (only before a change of behaviour)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
record=0; [ "${1-}" = --record ] && record=1
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf '#define W 3\nint a = W;\n' > a.cpp
printf '#define PRE 1\n' > pre.h
printf 'int in_stdin = 7;\n' > input.cpp
mkdir -p inc && printf '#define FROM_INC 4\n' > inc/inc.h

# the cases: NAME, then the arguments (one line each, word-split); stdin is input.cpp for every case
cases() {
  cat <<'EOF'
plain|-E a.cpp
std-define|-E -std=c++17 -DX=1 a.cpp
forced-include|-E -include pre.h a.cpp
output-file|-E a.cpp -o a.ii
stdin|-E -x c++ -
sysdir|-E -isystem inc a.cpp
xlang|-E -x c++ a.cpp
missing-source|-E missing.cpp
EOF
}

# run_case ARGS...: stdout, the -o file (if any), the driver's own stderr lines, and the status, as one text block
run_case() {
  local so se st
  so=$(cd "$work" && env -i PATH="$PATH" HOME="$HOME" RUBY="$(command -v ruby)" \
        ruby "$repo/scripts/nfcxx.rb" "$@" < input.cpp 2>"$work/stderr"; echo "status=$?")
  se=$(grep -E "^nfcxx:|error" "$work/stderr" | sed "s#$work#WORK#g")
  printf 'stdout:\n%s\nstderr:\n%s\n' "$so" "$se"
  for f in a.ii; do [ -f "$work/$f" ] && { echo "file $f:"; cat "$work/$f"; }; done
  rm -f "$work/a.ii"
}

while IFS='|' read -r name args; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2086
  got=$(run_case $args)
  if [ "$record" = 1 ]; then
    mkdir -p "$here/golden"; printf '%s\n' "$got" > "$here/golden/$name.txt"; pass=$((pass + 1))
  elif [ -f "$here/golden/$name.txt" ] && [ "$got" = "$(cat "$here/golden/$name.txt")" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name ($args)"
    [ -f "$here/golden/$name.txt" ] && diff <(cat "$here/golden/$name.txt") <(printf '%s\n' "$got") | sed 's/^/  /' | head -12
  fi
done < <(cases)

if [ "$record" = 1 ]; then echo "driver-preprocess: recorded $pass cases"; exit 0; fi
echo "driver-preprocess: $pass passed, $fail failed"
[ "$fail" = 0 ]
