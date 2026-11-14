#!/bin/bash
# Differential check of the CRuby driver (scripts/nfcxx.rb: the live gcc plan, run by scripts/nfcxx-run.rb, and bash for the
# rest) against nfcxx's bash, on this machine with the real toolchain (build/edg, the EH shim, gcc). Each case is a source
# set and an argument list: the bash builds it, the driver builds it, and the two must exit the same way and the programs
# must print the same. "route" is the driver's route (gcc-plan, pathb-plan: the Ruby plan built it; bash: the driver fell
# back). The cases name their backend (--backend=gcc, --backend=pathb, or none for the default, which is Path B). Needs the
# built EDG front end (scripts/setup-edg.sh); not run in CI.
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
cat > "$work/broken.cc" <<'SRC'
int main( { return 0; }
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
  "plain:--backend=gcc hello.cc -o prog"
  "dash-c:--backend=gcc -c hello.cc"
  "defs-opt:--backend=gcc hello.cc -O2 -DFOO=1 -o prog"
  "exceptions:--backend=gcc throw.cc -o prog"
  "c-only:--backend=gcc hello.c -o prog"
  "libm:--backend=gcc math.cc -lm -o prog"
  "isa:--backend=gcc -mavx2 hello.cc -o prog"
  "asan:--backend=gcc hello.cc -fsanitize=address -o prog"
  "gold:--backend=gcc hello.cc -fuse-ld=gold -o prog"
  "cuda-refused:--backend=gcc hello.cc -lcuda -o prog"
  "pathb-plain:--backend=pathb hello.cc -o prog"
  "pathb-exceptions:--backend=pathb throw.cc -o prog"
  "pathb-dash-c:--backend=pathb -c hello.cc"
  "pathb-asan:--backend=pathb hello.cc -fsanitize=address -o prog"
  "pathb-broken:--backend=pathb broken.cc -o prog"
  "default-plain:hello.cc -o prog"
  "default-broken:broken.cc -o prog"
)


run_case() {  # run_case NAME ARGS...: builds with the bash and with the driver (scripts/nfcxx.rb), and compares the programs
  local name=$1; shift
  local b="$work/$name-bash" p="$work/$name-drv"
  mkdir -p "$b" "$p"; cp "$work"/*.cc "$work"/*.c "$b"/; cp "$work"/*.cc "$work"/*.c "$p"/
  (cd "$b" && "$root/nfcxx" "$@" >"$b/build.log" 2>&1); local bs=$?
  (cd "$p" && NFCXX_DRIVER_TRACE=1 ruby "$root/scripts/nfcxx.rb" "$@" >"$p/build.log" 2>"$p/route"); local ps=$?
  local route; route=$(sed -n 's/^nfcxx: driver: //p' "$p/route")
  if [ "$bs" != "$ps" ]; then fail=$((fail + 1)); echo "FAIL      $name: build status bash=$bs driver=$ps"; return; fi
  if [ "$route" = bash ]; then unp=$((unp + 1)); echo "fallback  $name: the driver took the bash route"; fi
  if [ "$route" = pathb-plan ] && [ "$bs" != 0 ]; then echo "note      $name: the Path B plan failed (its status is the driver's)"; fi
  if [ "$bs" != 0 ]; then pass=$((pass + 1)); echo "pass      $name [$route] (both fail the same way, status $bs)"; return; fi
  if [ ! -e "$b/prog" ] && [ ! -e "$p/prog" ]; then  # -c: the object files are the result
    local bo po
    bo=$(cd "$b" && ls *.o 2>/dev/null); po=$(cd "$p" && ls *.o 2>/dev/null)
    if [ "$bo" = "$po" ] && [ -n "$bo" ]; then pass=$((pass + 1)); echo "pass      $name [$route] ($bo)"; else fail=$((fail + 1)); echo "FAIL      $name: objects bash [$bo] driver [$po]"; fi
    return
  fi
  local bo po
  bo=$("$b/prog" 2>&1; echo "status $?"); po=$("$p/prog" 2>&1; echo "status $?")
  if [ "$bo" = "$po" ]; then pass=$((pass + 1)); echo "pass      $name [$route]"; else fail=$((fail + 1)); echo "FAIL      $name: bash [$bo] driver [$po]"; fi
}

for c in "${cases[@]}"; do run_case "${c%%:*}" ${c#*:}; done
echo "passed $pass, failed $fail, bash fallbacks $unp"
[ "$fail" = 0 ]
