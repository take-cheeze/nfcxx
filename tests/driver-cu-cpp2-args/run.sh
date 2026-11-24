#!/bin/bash
# Stage B4 of docs/notes/driver-body-port.md: the CUDA, .cpp2 and C++ module refusals from the Ruby driver (scripts/nfcxx.rb,
# through scripts/nfcxx-cu-cpp2-args.rb). A command the input check refuses must give the bash's message on stderr and the
# bash's status, in the bash's order (the .cu preparation, the .cpp2 preparation, the module block, then the setup). Every
# other command goes to the bash oracle, so its output and status must match the bash too.
#   bash tests/driver-cu-cpp2-args/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
printf 'int main(){return 0;}\n' > m.cpp
printf 'export module mm;\nexport int f(){return 1;}\n' > mod.cc
printf 'export module mm:part;\n' > part.cc
printf 'import std;\nint main(){}\n' > stdimp.cc
printf 'int f(){return 0;}\n' > c.c
printf 'int main(){}\n' > x.cpp2
mkdir -p empty-cf

# same NAME: the driver's output (stdout, stderr and status) equals the bash's, for the arguments (word-split, as nfcxx-driver does)
check_same() {  # check_same ARG...
  local got want
  got=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  want=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1; echo "status=$?")
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $*"; echo "  driver: $got"; echo "  bash:   $want"; fi
}

# the refusals: the message on stderr and the status the bash gives (STATUS), and the same output as the bash
refused() {  # refused STATUS MESSAGE ARG...
  local want_status=$1 want_msg=$2; shift 2
  local got status
  got=$(ruby "$repo/scripts/nfcxx.rb" "$@" 2>&1 >/dev/null); status=$?
  if [ "$got" = "$want_msg" ] && [ "$status" = "$want_status" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL refused $*: status $status, want $want_status"; echo "  driver: $got"; echo "  want:   $want_msg"; fi
  check_same "$@"
}

# .cu: the source directory that does not exist (cu_copies' realpath, status 2) comes before the setup's refusals, as in the bash
refused 2 "realpath: /nonexistent/a: No such file or directory" -c /nonexistent/a/x.cu -o x.o
refused 2 "realpath: /nonexistent/a: No such file or directory" --backend=bogus -c /nonexistent/a/x.cu -o x.o
refused 2 "realpath: /nonexistent/a: No such file or directory" -std=c++17 -c /nonexistent/a/x.cu -o x.o
# .cpp2: the directory (status 1) and the file of the first input (status 1), before the setup's refusal
refused 1 "realpath: /nonexistent/a: No such file or directory" -c /nonexistent/a/x.cpp2 -o x.o
refused 1 "realpath: /nonexistent/a: No such file or directory" --backend=bogus -c /nonexistent/a/x.cpp2 -o x.o
refused 1 "realpath: /nonexistent/x.cpp2: No such file or directory" --backend=bogus -c /nonexistent/x.cpp2 -o x.o
# the first .cpp2 input is checked before the cppfront runs on it (the second input's directory is the oracle's)
refused 1 "realpath: /nonexistent/a: No such file or directory" -c /nonexistent/a/x.cpp2 x.cpp2 -o q.o
# cppfront's support files: CPPFRONT_SRC without include/cpp2util.h (status 2), before the setup's refusal
got=$(CPPFRONT_SRC="$work/empty-cf" ruby "$repo/scripts/nfcxx.rb" --backend=bogus -c x.cpp2 -o x.o 2>&1 >/dev/null); status=$?
want=$(CPPFRONT_SRC="$work/empty-cf" bash "$repo/nfcxx" --backend=bogus -c x.cpp2 -o x.o 2>&1 >/dev/null); wstatus=$?
if [ "$got" = "$want" ] && [ "$status" = 2 ] && [ "$wstatus" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL CPPFRONT_SRC: driver [$got] $status, bash [$want] $wstatus"; fi

# modules: the bash's module block, before the setup's refusals (the backend, for example)
refused 2 "nfcxx: part.cc: module partitions are not supported yet (docs/notes/modules.md)" -c part.cc m.cpp -o y.o
refused 2 "nfcxx: part.cc: module partitions are not supported yet (docs/notes/modules.md)" --backend=bogus -c mod.cc part.cc -o y.o
refused 2 "nfcxx: part.cc: module partitions are not supported yet (docs/notes/modules.md)" --backend=gcc -c part.cc -o p.o
refused 2 "nfcxx: part.cc: module partitions are not supported yet (docs/notes/modules.md)" --backend=bogus part.cc -o p
refused 2 "nfcxx: C++ modules need -std=c++20 or later" -std=c++17 -c mod.cc -o m.o
refused 2 "nfcxx: C sources cannot be built with C++ modules yet (docs/notes/modules.md)" -c mod.cc c.c -o y.o
refused 2 "nfcxx: stdimp.cc: import std: the standard library modules are not built yet (docs/notes/modules.md)" -c stdimp.cc m.cpp -o q.o
refused 2 "nfcxx: -c with C++ modules takes one source" -c mod.cc m.cpp -o m2.o
# a module source that the setup refuses: the module checks pass, then the setup's refusal (the backend)
refused 2 "nfcxx: unknown backend 'bogus'" --backend=bogus -c mod.cc -o m.o
# the .cu input before the module block: its refusal wins
refused 2 "realpath: /nonexistent/a: No such file or directory" -c /nonexistent/a/x.cu mod.cc -o y.o

# the oracle's: a missing .cu input is the rewriter's message, a .cpp2 input with a setup refusal is translated first, a module
# compile and a module link are the bash's (both give the bash's output and status)
check_same -c /nonexistent/x.cu -o x.o
check_same --backend=bogus -c x.cpp2 -o x.o
check_same -c mod.cc -o m5.o
check_same mod.cc -o a.out
check_same -c m.cpp -o m.o

echo "driver-cu-cpp2-args: $pass passed, $fail failed"
[ $fail = 0 ]
