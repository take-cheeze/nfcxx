#!/bin/bash
# The CRuby driver (scripts/nfcxx.rb) must behave as the bash driver (nfcxx) for every argument list: the same output, error
# messages and exit status. It also must plan the pre-loop steps the port models (-fsyntax-only, --bundle-*) and send the
# rest to the bash. This host has no EDG build, so every compile ends with the same "EDG not built" error on both sides.
cd "$(dirname "$0")/../.." || exit 1
pass=0; fail=0
cases=(
  "-fsyntax-only x.cc"
  "--bundle-libs x.cc"
  "-c x.cc"
  "-E x.cc"
  "-o p x.cc"
  "--bogus x.cc"
  "--cuda-driver=cudart x.cc -lcuda"
  "--backend=gcc -c a.cc -o a.o"
  "-c a.cc b.cc"
)
for c in "${cases[@]}"; do
  read -r -a args <<< "$c"
  got=$(ruby scripts/nfcxx.rb "${args[@]}" 2>&1; echo "status=$?")
  want=$(bash "$PWD/nfcxx" "${args[@]}" 2>&1; echo "status=$?")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $c"; echo "  driver: $got"; echo "  bash:   $want"; fi
done
# the dispatch: the pre-loop re-run and bundle steps are planned; the others go to the bash
dispatch() { NFCXX_DRIVER_TRACE=1 ruby scripts/nfcxx.rb "$@" 2>&1 >/dev/null | grep '^nfcxx: driver:' ; }
check_dispatch() {  # check_dispatch EXPECTED ARG...
  local want=$1; shift
  local got; got=$(dispatch "$@")
  if [ "$got" = "nfcxx: driver: $want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL dispatch $* want $want got [$got]"; fi
}
check_dispatch plan -fsyntax-only x.cc
check_dispatch plan --bundle-libs x.cc
check_dispatch bash -c x.cc
check_dispatch bash -E x.cc
check_dispatch bash --bogus x.cc
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
