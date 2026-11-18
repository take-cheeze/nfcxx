#!/bin/bash
# The Ruby driver skeleton (NFCXX_RUBY_DRIVER=1, scripts/nfcxx.rb) gives the bash driver's status, stdout and stderr for the
# common requests. Each case runs both on the same files; temporary directory names are normalized out of stderr.
#   bash tests/ruby-driver-smoke/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int f(int x){return x+1;}\n' > a.c
printf 'int main(){return 0;}\n' > m.cpp
printf 'int main( {\n' > bad.cpp

# temporary directory names, and the date EDG writes in the comment of --emit-c output, are not the driver's behaviour
norm() { sed -e 's#/tmp/[A-Za-z0-9._-]*#TMP#g' -e 's#^/\* .* 20[0-9][0-9] \*/$#/* DATE */#' "$1"; }

run_case() {
  local name=$1; shift
  "$repo/nfcxx" "$@" >bash.out 2>bash.err; bst=$?
  NFCXX_RUBY_DRIVER=1 "$repo/nfcxx" "$@" >ruby.out 2>ruby.err; rst=$?
  if [ "$bst" = "$rst" ] && cmp -s <(norm bash.out) <(norm ruby.out) && cmp -s <(norm bash.err) <(norm ruby.err); then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name (status bash=$bst ruby=$rst)"
    diff <(norm bash.out) <(norm ruby.out) | head -3; diff <(norm bash.err) <(norm ruby.err) | head -3
  fi
}

run_case "compile C++ to an object" -c m.cpp -o m.o
run_case "link C++" -o pm m.cpp
run_case "compile C" -c a.c -o a.o
run_case "syntax only" -fsyntax-only m.cpp
run_case "emit C" --emit-c m.cpp
run_case "preprocess" -E m.cpp
run_case "syntax error" -c bad.cpp -o b.o
run_case "missing input" -c nosuch.cpp -o n.o

echo "ruby-driver-smoke: $pass passed, $fail failed"
[ $fail = 0 ]
