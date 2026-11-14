#!/bin/bash
# Differential check of the live gcc plan (scripts/nfcxx-gcc-plan.rb --live=ROOT, run by scripts/nfcxx-run.rb) against
# nfcxx's bash, on this machine with the real toolchain (build/edg, the EH shim, gcc). Each case is a source set and an
# argument list: the bash builds it, the plan builds it, and the two programs must print the same and exit the same way.
# A case the plan refuses (exit 3, "unported") is reported as unported, not as a failure: the live facts refuse what they
# do not model. Needs the built EDG front end (scripts/setup-edg.sh); not run in CI.
#   bash tests/nfcxx-live/run.sh
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0; unp=0

cat > "$work/hello.cc" <<'SRC'
#include <cstdio>
int main(int argc, char **argv) { std::printf("hello %d %d\n", 42, argc); return 0; }
SRC
cat > "$work/throw.cc" <<'SRC'
#include <cstdio>
#include <stdexcept>
int main() { try { throw std::runtime_error("boom"); } catch (const std::exception &e) { std::printf("caught %s\n", e.what()); } return 0; }
SRC
cat > "$work/hello.c" <<'SRC'
#include <stdio.h>
int main(void) { printf("c %d\n", 7); return 0; }
SRC
cat > "$work/math.cc" <<'SRC'
#include <cmath>
#include <cstdio>
int main() { std::printf("%.3f\n", std::sqrt(2.0)); return 0; }
SRC

# one case: NAME, then the arguments of the build; the source files are in $work
cases=(
  "plain:hello.cc -o prog"
  "dash-c:-c hello.cc"
  "defs-opt:hello.cc -O2 -DFOO=1 -o prog"
  "exceptions:throw.cc -o prog"
  "c-only:hello.c -o prog"
  "libm:math.cc -lm -o prog"
  "isa:-mavx2 hello.cc -o prog"
  "asan:hello.cc -fsanitize=address -o prog"
  "gold:hello.cc -fuse-ld=gold -o prog"
  "cuda-refused:hello.cc -lcuda -o prog"
)

run_case() {  # run_case NAME ARGS...: builds with the bash and the plan in two directories, compares the programs
  local name=$1; shift
  local b="$work/$name-bash" p="$work/$name-plan"
  mkdir -p "$b" "$p"; cp "$work"/*.cc "$work"/*.c "$b"/; cp "$work"/*.cc "$work"/*.c "$p"/
  (cd "$b" && "$root/nfcxx" --backend=gcc "$@" >"$b/build.log" 2>&1); local bs=$?
  (cd "$p" && ruby "$root/scripts/nfcxx-gcc-plan.rb" --tabs --live="$root" --backend=gcc "$@" >"$p/plan.txt" 2>"$p/plan.err"); local ps=$?
  if [ $ps = 3 ]; then unp=$((unp + 1)); echo "unported  $name: $(head -1 "$p/plan.err")"; return; fi
  if [ $ps != 0 ]; then fail=$((fail + 1)); echo "FAIL      $name: the plan printer exited $ps: $(head -1 "$p/plan.err")"; return; fi
  (cd "$p" && ruby "$root/scripts/nfcxx-run.rb" --root="$root" --chdir="$p" --plan="$p/plan.txt" >"$p/build.log" 2>&1); local rs=$?
  if [ $bs != $rs ]; then fail=$((fail + 1)); echo "FAIL      $name: build status bash=$bs plan=$rs"; return; fi
  if [ "$bs" != 0 ]; then pass=$((pass + 1)); echo "pass      $name (both fail the same way, status $bs)"; return; fi
  local bo po
  if [ ! -e "$b/prog" ] && [ ! -e "$p/prog" ]; then  # -c: the object files are the result
    bo=$(cd "$b" && ls *.o 2>/dev/null); po=$(cd "$p" && ls *.o 2>/dev/null)
    if [ "$bo" = "$po" ] && [ -n "$bo" ]; then pass=$((pass + 1)); echo "pass      $name ($bo)"; else fail=$((fail + 1)); echo "FAIL      $name: objects bash [$bo] plan [$po]"; fi
    return
  fi
  bo=$("$b/prog" 2>&1; echo "status $?"); po=$("$p/prog" 2>&1; echo "status $?")
  if [ "$bo" = "$po" ]; then pass=$((pass + 1)); echo "pass      $name"; else fail=$((fail + 1)); echo "FAIL      $name: bash [$bo] plan [$po]"; fi
}

for c in "${cases[@]}"; do run_case "${c%%:*}" ${c#*:}; done
echo "passed $pass, failed $fail, unported $unp"
[ "$fail" = 0 ]
