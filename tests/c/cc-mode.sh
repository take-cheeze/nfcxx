#!/usr/bin/env bash
# nfcc (the drop-in cc wrapper): invoke it the way make, rake and autoconf do, on both backends.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD; nfcc=$root/nfcc
backends=${NFCXX_BACKEND:-"gcc qbe"}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $b $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $b $1: $2"; fail=$((fail + 1)); }
# check NAME CMD...: CMD succeeds
check() { local n=$1; shift; if out=$("$@" 2>&1); then ok "$n"; else bad "$n" "$(head -3 <<<"$out" | tr '\n' ' ')"; fi; }
# rejects NAME EXPECTED-TEXT ARGS...: nfcc exits non-zero, says nfcc: error: ... EXPECTED-TEXT, writes no output file
rejects() {
  local n=$1 want=$2; shift 2
  rm -f "$w/rej.o"
  if out=$("$nfcc" "$@" 2>&1); then bad "reject $n" "was accepted"
  elif ! grep -q "^nfcc: error: .*$want" <<<"$out"; then bad "reject $n" "message was: $(head -2 <<<"$out" | tr '\n' ' ')"
  elif [ -e "$w/rej.o" ]; then bad "reject $n" "wrote output anyway"
  else ok "reject $n"; fi
}

for b in $backends; do
  export NFCXX_BACKEND=$b
  w=$tmp/$b; mkdir -p "$w/inc" "$w/sys" "$w/lib" && cd "$w" || exit 1

  cat > inc/cfg.h <<'EOF'
#define CFG_VALUE 30
EOF
  cat > sys/sysh.h <<'EOF'
#define SYS_VALUE 5
EOF
  cat > pre.h <<'EOF'
#define PRE_VALUE 7
EOF
  cat > main.c <<'EOF'
#include <stdio.h>
#include "util.h"
#include <cfg.h>
#include <sysh.h>
int main(void) {
  printf("%d\n", util_add(CFG_VALUE, SYS_VALUE) + PRE_VALUE + EXTRA);   /* 36+7+100 */
  return util_add(CFG_VALUE, SYS_VALUE) + PRE_VALUE + EXTRA- 142;        /* 143 - 142 */
}
EOF
  cat > util.h <<'EOF'
int util_add(int, int);
EOF
  cat > util.c <<'EOF'
#include "util.h"
int util_add(int a, int b) { return a + b + 1; }
EOF

  # 1. compile + link with the usual flag soup; the exit code proves -D -I -isystem -include all took effect.
  check "compile -c -o with flags" "$nfcc" -O2 -g -Wall -Wextra -Wno-unused -w -pipe -pthread -m64 -fPIC -fno-strict-aliasing \
      -fwrapv -fvisibility=hidden -fno-omit-frame-pointer -std=c99 -DEXTRA=100 -Iinc -isystem sys -include pre.h -c main.c -o main.o
  check "compile util.c" "$nfcc" -c util.c -o util.o
  check "link objects -o" "$nfcc" main.o util.o -o prog
  ./prog >out.txt; rc=$?
  if [ $rc = 1 ] && [ "$(cat out.txt)" = 143 ]; then ok "run: exit 1, prints 143"; else bad "run" "rc=$rc out=$(cat out.txt)"; fi
  check "-D value / -I dir as separate arguments" "$nfcc" -D EXTRA=1 -I inc -isystem sys -include pre.h -c main.c -o sep.o
  check "-U overrides" "$nfcc" -DEXTRA=1 -UEXTRA -DEXTRA=2 -Iinc -isystem sys -include pre.h -c main.c -o u.o
  check "compile+link in one command, several .c" "$nfcc" -DEXTRA=100 -Iinc -isystem sys -include pre.h main.c util.c -lm -o oneshot
  ./oneshot >/dev/null; [ $? = 1 ] && ok "one-step build runs" || bad "one-step build runs" "wrong exit code"
  check "no -o with -c names the object after the source" bash -c "cd '$w' && mkdir -p nolo && cp util.c util.h nolo/ && cd nolo && '$nfcc' -c util.c && test -f util.o"
  rejects "-o with -c and two sources" "multiple files" -c util.c main.c -o rej.o

  # 2. dependency files
  check "-MMD -MP -MF -MT" "$nfcc" -DEXTRA=1 -Iinc -isystem sys -include pre.h -MMD -MP -MF dep1.d -MT custom.o -c main.c -o d1.o
  if grep -q '^custom.o:' dep1.d && grep -q 'util.h' dep1.d && grep -q 'inc/cfg.h' dep1.d && ! grep -q 'sys/sysh.h' dep1.d \
     && grep -q '^util.h:' dep1.d; then ok "-MMD: target, user headers, no system header, phony targets"
  else bad "-MMD dependency file" "$(tr '\n' ' ' < dep1.d)"; fi
  check "-MD default file name" "$nfcc" -DEXTRA=1 -Iinc -isystem sys -include pre.h -MD -c main.c -o dd.o
  if [ -f dd.d ] && grep -q '^dd.o:' dd.d && grep -q 'sys/sysh.h' dd.d; then ok "-MD: dd.d, target dd.o, system headers kept"
  else bad "-MD default" "$(tr '\n' ' ' < dd.d 2>/dev/null)"; fi

  # 3. a Makefile the way a project writes it: CC=nfcc, -MMD, include the .d files, ar for the library.
  mkdir -p mk && cd mk || exit 1
  cp ../util.c ../util.h ../main.c ../pre.h . && cp -r ../inc ../sys .
  cat > Makefile <<'EOF'
CFLAGS = -O2 -g -Wall -DEXTRA=100 -Iinc -isystem sys -include pre.h
OBJS = main.o
all: prog
%.o: %.c
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@
libutil.a: util.o
	$(AR) rcs $@ $^
prog: $(OBJS) libutil.a
	$(CC) -o $@ $(OBJS) -L. -lutil -lm
-include $(OBJS:.o=.d) util.d
clean:
	rm -f *.o *.d *.a prog
EOF
  if make CC="$nfcc" >make1.log 2>&1 && ./prog >/dev/null; [ $? = 1 ]; then ok "make CC=nfcc builds and the program runs"
  else bad "make CC=nfcc" "$(tail -3 make1.log | tr '\n' ' ')"; fi
  [ -f main.d ] && [ -f util.d ] && ok "make: .d files written" || bad "make: .d files" "missing"
  if make CC="$nfcc" 2>&1 | grep -q "Nothing to be done\|is up to date"; then ok "make: second run is a no-op"
  else bad "make: second run" "rebuilt"; fi
  sleep 1; touch util.h
  make CC="$nfcc" >make2.log 2>&1
  if grep -q 'main.c' make2.log && grep -q 'util.c' make2.log; then ok "make: touching a header rebuilds the dependents (via -MMD)"
  else bad "make: header dependency" "$(tr '\n' ' ' < make2.log)"; fi
  cd "$w" || exit 1

  # 4. static archive + -L/-l, shared object
  mkdir -p lib && "$nfcc" -c util.c -o lib/util.o && ar rcs lib/libu.a lib/util.o
  check "link with -L -l static archive" "$nfcc" -DEXTRA=100 -Iinc -isystem sys -include pre.h main.c -Llib -lu -o viaar
  ./viaar >/dev/null; [ $? = 1 ] && ok "archive-linked program runs" || bad "archive-linked program" "wrong exit"
  cat > so.c <<'EOF'
int so_value = 5;
int so_get(void) { return so_value + 4; }
EOF
  cat > soterm.c <<'EOF'
int so_get(void);
int main(void) { return so_get(); }
EOF
  check "-fPIC -shared" bash -c "'$nfcc' -fPIC -c so.c -o so.o && '$nfcc' -shared so.o -o libso.so"
  check "link against the shared object" "$nfcc" soterm.c -L. -lso -Wl,-rpath,"$w" -o soterm
  ./soterm; [ $? = 9 ] && ok "shared object works" || bad "shared object" "wrong exit"

  # 5. preprocessing, language, stdin, queries
  check "-E goes to the host preprocessor" bash -c "'$nfcc' -E -P -DEXTRA=1 -Iinc -isystem sys -include pre.h main.c | tr -d ' \n' | grep -q 'util_add(30,5)'"
  check "-E -dM - (autoconf macro probe)" bash -c "echo | '$nfcc' -E -dM -x c - | grep -q __STDC__"
  check "-M passes through" bash -c "'$nfcc' -M -Iinc -isystem sys -include pre.h main.c | grep -q util.h"
  check "-x c with a non-.c name" bash -c "cp util.c util.txt && '$nfcc' -x c -c util.txt -o xc.o"
  check "-x c - (stdin)" bash -c "echo 'int f(void){return 3;}' | '$nfcc' -x c -c - -o stdin.o && test -s stdin.o"
  check "--version" bash -c "'$nfcc' --version | head -1 | grep -q nfcc"
  check "-dumpmachine" bash -c "test \"\$('$nfcc' -dumpmachine)\" = \"\$(cc -dumpmachine)\""
  check "-dumpversion" bash -c "'$nfcc' -dumpversion | grep -q '^[0-9]'"
  check "-v alone" bash -c "'$nfcc' -v 2>&1 | grep -q 'gcc version'"
  # autoconf-style probes: tiny program compile/link/run, no output name -> a.out
  mkdir -p conf && echo 'int main(void) { return 0; }' > conf/conftest.c
  check "autoconf probe: compile, link, run conftest" bash -c "cd conf && '$nfcc' conftest.c -o conftest && ./conftest && '$nfcc' conftest.c && ./a.out && '$nfcc' -c conftest.c && test -f conftest.o"
  check "autoconf probe: -Werror -Wall is accepted" bash -c "cd conf && '$nfcc' -Werror -Wall -Wextra -c conftest.c -o /dev/null"
  check "autoconf probe: a failing compile fails" bash -c "cd conf && echo 'int main(void) { return x; }' > bad.c && ! '$nfcc' -c bad.c -o bad.o"
  # a real C syntax error must not be swallowed
  echo 'int main( { }' > conf/syn.c
  check "syntax error is an error" bash -c "cd conf && ! '$nfcc' -c syn.c -o syn.o"

  # 6. unsupported options fail loudly and write nothing
  rejects "-S" "-S" -S util.c -o rej.o
  rejects "-m32" "m32" -m32 -c util.c -o rej.o
  rejects "-fsanitize=address" "fsanitize" -fsanitize=address -c util.c -o rej.o
  rejects "-fopenmp" "fopenmp" -fopenmp -c util.c -o rej.o
  rejects "-ffast-math" "ffast-math" -ffast-math -c util.c -o rej.o
  rejects "-funsigned-char" "funsigned-char" -funsigned-char -c util.c -o rej.o
  rejects "--coverage" "coverage" --coverage -c util.c -o rej.o
  rejects "-std=c++17" "C++" -std=c++17 -c util.c -o rej.o
  rejects "-x c++" "c++" -x c++ -c util.c -o rej.o
  rejects ".cpp input" "nfcxx" -c foo.cpp -o rej.o
  rejects "-Wp," "Wp" -Wp,-MD,x.d -c util.c -o rej.o
  rejects "unknown -f option" "fmade-up" -fmade-up-option -c util.c -o rej.o
  rejects "unknown option" "frobnicate" --frobnicate -c util.c -o rej.o
  rejects "response file" "response" @args -c util.c -o rej.o
  rejects "no input" "no input" -c -o rej.o
  rejects "-MD without -c" "needs -c" -MD util.c -o rej.o
  if [ $b = qbe ]; then   # qbe-prep lowers __builtin_add_overflow only for operands of one type; a mix is not converted silently
    echo 'int main(void) { long a; int x = 1; return __builtin_add_overflow(x, x, &a); }' > mix.c
    if out=$("$nfcc" mix.c -o mix 2>&1); then bad "mixed-type __builtin_add_overflow" "linked"
    elif grep -q overflow_unsupported_operand_types <<<"$out"; then ok "mixed-type __builtin_add_overflow fails at link, naming the symbol"
    else bad "mixed-type __builtin_add_overflow" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
  fi
  cd "$root" || exit 1
done
echo "tests/c/cc-mode: $pass passed, $fail failed"
[ $fail -eq 0 ]
