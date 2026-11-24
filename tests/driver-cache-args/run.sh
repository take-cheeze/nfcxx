#!/bin/bash
# Stage B5 of docs/notes/driver-body-port.md: the cache configuration's refusal from the Ruby driver (scripts/nfcxx.rb, through
# scripts/nfcxx-cache-config.rb). The bash checks NFCXX_CACHE_REMOTE first (its line 115, before the argument loop, the routes, the
# setup and its trace), so a bad value gives the bash's message and status 2 for every command, and no trace file is made. The
# other commands: the launcher (./nfcxx) must pass the driver's output and status through unchanged (the bash oracle is retired).
#   bash tests/driver-cache-args/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > m.cpp
unset NFCXX_CACHE NFCXX_CACHE_LOG NFCXX_CACHE_REMOTE

# same NAME: the driver's output (stdout, stderr and status) equals the bash's, for the arguments (word-split, as nfcxx-driver does)
check_same() {  # check_same ARG...
  local got want
  got=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  want=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*"; echo "  driver: $got"; echo "  bash:   $want"; fi
}

# the refusals with NFCXX_CACHE_REMOTE=bogus (in the environment of both drivers): the message on stderr and status 2, and the bash's
# output
refused() {  # refused MESSAGE ARG...
  local want_msg=$1; shift
  local got status
  got=$(NFCXX_CACHE_REMOTE=bogus ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1 >/dev/null); status=$?
  if [ "$got" = "$want_msg" ] && [ "$status" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL refused $*: status $status"; echo "  driver: $got"; echo "  want:   $want_msg"; fi
  export NFCXX_CACHE_REMOTE=bogus
  check_same "$@"
  unset NFCXX_CACHE_REMOTE
}

msg="nfcxx: NFCXX_CACHE_REMOTE takes gha (got 'bogus')"
refused "$msg" -c m.cpp -o m.o
refused "$msg" --version
refused "$msg" -E m.cpp
refused "$msg" --cache="$work/c" -c m.cpp -o m.o
refused "$msg" --backend=bogus -c m.cpp -o m.o
# the cache configuration comes before the setup and the gcc route (a command the gcc planner refuses): the bash's order
refused "$msg" --backend=gcc -fsanitize=thread m.cpp -o prog
refused "$msg" -c /nonexistent/a/x.cu -o x.o

# the bash ends before its trace begins: no trace file is made by either driver
rm -f "$work/t.trace"
NFCXX_CACHE_REMOTE=bogus ruby "$repo/scripts/nfcxx.rb" --trace="$work/t.trace" -c m.cpp -o m.o >/dev/null 2>&1
if [ ! -e "$work/t.trace" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL trace file made for a refused command"; fi

# -fsyntax-only is the oracle's (the bash's pre-loop plan runs first): the same output and status
export NFCXX_CACHE_REMOTE=bogus
check_same -fsyntax-only m.cpp
check_same --backend=bogus -fsyntax-only m.cpp
unset NFCXX_CACHE_REMOTE

# a valid or empty value is not refused here: the oracle runs the command, the same output and status as the bash
export NFCXX_CACHE_REMOTE=gha
check_same --backend=bogus -c m.cpp -o m.o
check_same --backend=gcc -fsanitize=thread m.cpp -o prog
unset NFCXX_CACHE_REMOTE
export NFCXX_CACHE_REMOTE=
check_same --backend=bogus -c m.cpp -o m.o
unset NFCXX_CACHE_REMOTE

# the mapping of the cache configuration (scripts/nfcxx-cache-config.rb plan): the variables the bash's eval gives, the same as the
# bash's own assignments (the cache directory of a remote-only setting, the empty values as unset)
for env_case in "NFCXX_CACHE=d NFCXX_CACHE_LOG=l NFCXX_CACHE_REMOTE=gha" "NFCXX_CACHE_REMOTE=gha" "NFCXX_CACHE=d" "NFCXX_CACHE_LOG=l"; do
  got=$(env -i PATH="$PATH" TMPDIR="$work/tmp" $env_case bash -c 'eval "$(ruby "$1" plan)"; printf "%s|%s|%s" "$cache_dir" "$cache_log_file" "$cache_remote"' _ "$repo/scripts/nfcxx-cache-config.rb")
  want=$(env -i PATH="$PATH" TMPDIR="$work/tmp" $env_case bash -c 'cache_dir=${NFCXX_CACHE:-}; cache_log_file=${NFCXX_CACHE_LOG:-}; cache_remote=${NFCXX_CACHE_REMOTE:-}
[ -n "$cache_dir" ] || [ -z "$cache_remote" ] || cache_dir=${TMPDIR:-/tmp}/nfcxx-cache-$(id -u)
printf "%s|%s|%s" "$cache_dir" "$cache_log_file" "$cache_remote"')
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL cache plan [$env_case]: [$got] [$want]"; fi
done

echo "driver-cache-args: $pass passed, $fail failed"
[ $fail = 0 ]
