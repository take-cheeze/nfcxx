#!/bin/bash
# Stage B3 of docs/notes/driver-body-port.md: the setup's refusals from the Ruby driver (scripts/nfcxx.rb, through
# scripts/nfcxx-setup-args.rb). A command the setup refuses must give the bash's message, on stderr, and the bash's status; the
# command goes to the bash oracle otherwise, so every other case must match the bash too. The mapping of the argument loop's
# state to the setup's keys is checked as well (scripts/nfcxx-setup-args.rb prints them).
#   bash tests/driver-setup-args/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > m.cpp

# same NAME: the driver's output (stdout, stderr and status) equals the bash's, for the arguments (word-split, as nfcxx-driver does)
check_same() {  # check_same ARG...
  local got want
  got=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  want=$("$repo/nfcxx" "$@" 2>&1; echo "status=$?")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*"; echo "  driver: $got"; echo "  bash:   $want"; fi
}

# the refusals: the setup's message and status 2, as the bash prints them
refused() {  # refused MESSAGE ARG...
  local want_msg=$1; shift
  local got status
  got=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1 >/dev/null); status=$?
  if [ "$got" = "$want_msg" ] && [ "$status" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL refused $*: status $status"; echo "  driver: $got"; echo "  want:   $want_msg"; fi
  check_same "$@"
}

# the bash's own messages for the refusals (scripts/nfcxx.rb prints the same text the setup's planner prints)
refused "nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got bogus)" --instantiate=bogus -c m.cpp -o m.o
refused "nfcxx: unknown backend 'bogus'" --backend=bogus -c m.cpp -o m.o
refused "nfcxx: --target needs --freestanding (the host's library headers are the host target's)" --target=linux_aarch64 -c m.cpp -o m.o
refused "nfcxx: --target needs --emit-c (the generated C is for the target; compile it with a cross compiler)" --target=linux_aarch64 --freestanding -c m.cpp -o m.o
refused "nfcxx: -fsanitize=address: unknown backend bogus" -fsanitize=address --backend=bogus -c m.cpp -o m.o
refused "nfcxx: --cosmo needs --backend=gcc or --backend=pathb" --cosmo --backend=bogus -c m.cpp -o m.o
# the order of the setup's steps: the first refusal in the bash's order is the one printed
refused "nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got bogus)" --instantiate=bogus --backend=bogus -c m.cpp -o m.o
# a missing source: the bash's module scan reports it before its setup, so the command is the oracle's (both lines are the bash's)
check_same --backend=bogus -c nosuch.cc -o a.o
# the backend comes from the environment (NFCXX_BACKEND), as the bash reads it
got=$(NFCXX_BACKEND=bogus ruby "$repo/scripts/nfcxx.rb" -c m.cpp -o m.o 2>&1 >/dev/null); st=$?
want=$(NFCXX_BACKEND=bogus "$repo/nfcxx" -c m.cpp -o m.o 2>&1 >/dev/null); wst=$?
if [ "$got" = "$want" ] && [ "$st" = 2 ] && [ "$wst" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL NFCXX_BACKEND=bogus: driver [$got] $st, bash [$want] $wst"; fi

# the commands the setup does not refuse, and the ones the bash ends before its setup, go to the bash: the same output and status
check_same -fsyntax-only m.cpp
check_same --backend=bogus -fsyntax-only m.cpp
check_same -E m.cpp
check_same --backend=bogus -E m.cpp
check_same -c m.cpp -o m.o
check_same --backend=bogus -c
check_same -c -I
check_same --instantiate=auto -fsanitize=address -fsyntax-only m.cpp
check_same --target=linux_k1om --freestanding -c m.cpp -o m.o

# the mapping: the loop's state as the setup's keys (scripts/nfcxx-setup-args.rb prints KEY=VALUE, the bash names)
keys() { ruby "$repo/scripts/nfcxx-setup-args.rb" "$@"; }
has() {  # has KEY=VALUE ARG...: the setup options for ARG... include KEY=VALUE
  local want=$1; shift
  if keys "$@" | grep -qxF -- "$want"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL keys $*: no $want"; fi
}
has backend_explicit=1 --backend=gcc -c m.cpp -o m.o
has backend_explicit=0 -c m.cpp -o m.o
has path_b=1 --backend=pathb -c m.cpp -o m.o
has instantiate=auto --instantiate=auto -c m.cpp -o m.o
has instantiate=used -c m.cpp -o m.o
has target=linux_aarch64 --target=linux_aarch64 -c m.cpp -o m.o
has freestanding=1 --freestanding -c m.cpp -o m.o
has cosmo=1 --cosmo -c m.cpp -o m.o
has gnu=130000 --gnu-version=130000 -c m.cpp -o m.o
has dialect=clang --dialect=clang -c m.cpp -o m.o
has dialect_asked=1 --dialect=clang -c m.cpp -o m.o
has asan=1 -fsanitize=address -c m.cpp -o m.o
has asanopts=-fno-omit-frame-pointer -fsanitize=address -fno-omit-frame-pointer -c m.cpp -o m.o
has depmode=-MD -MD -c m.cpp -o m.o
has shared=1 -shared m.cpp -o x.so
has "root=$repo" -c m.cpp -o m.o
has "sys=$(uname -s)" -c m.cpp -o m.o
has "mach=$(uname -m)" -c m.cpp -o m.o
has "host=$(uname -s) $(uname -m)" -c m.cpp -o m.o

echo "driver-setup-args: $pass passed, $fail failed"
[ $fail = 0 ]
