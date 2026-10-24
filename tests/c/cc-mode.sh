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
  check "-v alone" bash -c "'$nfcc' -v 2>&1 | grep -q 'version'"
  # autoconf-style probes: tiny program compile/link/run, no output name -> a.out
  mkdir -p conf && echo 'int main(void) { return 0; }' > conf/conftest.c
  check "autoconf probe: compile, link, run conftest" bash -c "cd conf && '$nfcc' conftest.c -o conftest && ./conftest && '$nfcc' conftest.c && ./a.out && '$nfcc' -c conftest.c && test -f conftest.o"
  check "autoconf probe: -Werror -Wall is accepted" bash -c "cd conf && '$nfcc' -Werror -Wall -Wextra -c conftest.c -o /dev/null"
  check "autoconf probe: a failing compile fails" bash -c "cd conf && echo 'int main(void) { return x; }' > bad.c && ! '$nfcc' -c bad.c -o bad.o"
  # a real C syntax error must not be swallowed
  echo 'int main( { }' > conf/syn.c
  check "syntax error is an error" bash -c "cd conf && ! '$nfcc' -c syn.c -o syn.o"

  # 6. -S, response files, -Wp,/-Wa,, -O/-g
  check "-S writes assembly named after the source" bash -c "cd '$w' && mkdir -p sdir && cp util.c util.h sdir/ && cd sdir && '$nfcc' -S util.c && grep -q util_add util.s && ! test -e util.o"
  check "-S -o names the assembly file" "$nfcc" -S util.c -o util_out.s
  check "-S output assembles and links into a working program" bash -c "'$nfcc' -DEXTRA=100 -Iinc -isystem sys -include pre.h -c main.c -o smain.o && cc -c util_out.s -o sutil.o && '$nfcc' smain.o sutil.o -o sprog && ./sprog >/dev/null; test \$? = 1"
  check "-S -o - writes to stdout" bash -c "'$nfcc' -S util.c -o - | grep -q util_add"
  check "-S with several sources gives one .s each" bash -c "cd '$w' && mkdir -p smulti && cp util.c util.h so.c smulti/ && cd smulti && '$nfcc' -S util.c so.c && test -s util.s && test -s so.s"
  rejects "-S with -o and two sources" "multiple files" -S util.c main.c -o rej.o
  check "-S -MMD writes the dependency file" bash -c "cd '$w' && '$nfcc' -S -MMD -MF sdep.d -DEXTRA=1 -Iinc -isystem sys -include pre.h main.c -o sdep.s && grep -q util.h sdep.d && test -s sdep.s"
  mkdir -p "inc dir" && cp inc/cfg.h "inc dir/"
  printf '%s\n' '-DEXTRA=100 -I"inc dir"' "-isystem 'sys'" '@rsp_inner.txt' > rsp_outer.txt
  printf '%s\n' '-include' 'pre.h -c' > rsp_inner.txt
  check "@file: quotes, newlines and nested @file" "$nfcc" @rsp_outer.txt main.c -o rsp.o
  check "@file: the options took effect" bash -c "'$nfcc' rsp.o util.o -o rspprog && ./rspprog >/dev/null; test \$? = 1"
  printf '%s' 'int main(void) { return 5; }' > "main five.c"
  printf '%s\n' '"main five.c" -o five\ prog' > rsp_names.txt
  check "@file: a quoted name and a backslash-escaped space" bash -c "'$nfcc' @rsp_names.txt && ./five\ prog; test \$? = 5"
  printf '%s\n' -DEXTRA=7 > rsp_d.txt
  echo 'int main(void) { return EXTRA; }' > rv.c
  check "@file with ordinary arguments" bash -c "'$nfcc' @rsp_d.txt rv.c -o rv && ./rv; test \$? = 7"
  check "@file: a later option overrides the response file's" bash -c "'$nfcc' @rsp_d.txt -UEXTRA -DEXTRA=9 rv.c -o rv && ./rv; test \$? = 9"
  rejects "unreadable response file" "@no_such_response_file" @no_such_response_file -c util.c -o rej.o
  check "-Wp,-D,-I,-include" "$nfcc" -Wp,-DEXTRA=100,-Iinc,-isystem,sys,-include,pre.h -c main.c -o wp.o
  check "-Wp,-MMD,file" bash -c "'$nfcc' -Wp,-DEXTRA=1,-Iinc,-isystem,sys,-include,pre.h,-MMD,wp.d -c main.c -o wp2.o && grep -q util.h wp.d"
  check "-Wa,... is handed to the assembler" "$nfcc" -Wa,--noexecstack -c util.c -o wa.o
  rejects "-Wp,-foo" "Wp,-foo.*not supported" -Wp,-foo -c util.c -o rej.o
  rejects "-Wp,-DX,-foo (every item is checked)" "'-foo' is not supported" -Wp,-DX,-foo -c util.c -o rej.o
  rejects "-Ofast" "Ofast" -Ofast -c util.c -o rej.o
  rejects "unknown -O" "optimisation" -Oz -c util.c -o rej.o
  printf '%s\n' 'int f(int x) { return x * 3; }' > opt.c
  if [ $b = gcc ]; then
    # The marker -O0 leaves and -O2 drops: the frame pointer rbp on x86-64; on aarch64 the stack frame (sub sp, sp, N).
    fp=rbp; [ "$(uname -m)" = x86_64 ] || fp='sp, sp,'
    "$nfcc" -S opt.c -o opt_def.s; "$nfcc" -O0 -S opt.c -o opt0.s; "$nfcc" -O2 -S opt.c -o opt2.s; "$nfcc" -S -g opt.c -o optg.s
    "$nfcc" -O0 -O3 -S opt.c -o opt03.s; "$nfcc" -O3 -S opt.c -O0 -o opt30.s
    if grep -q "$fp" opt0.s && ! grep -q "$fp" opt2.s && ! grep -q "$fp" opt_def.s; then ok "gcc backend: -O0 is unoptimised, -O2 and the default optimise"
    else bad "gcc backend -O levels" "$fp in -O0: $(grep -c "$fp" opt0.s) -O2: $(grep -c "$fp" opt2.s) default: $(grep -c "$fp" opt_def.s)"; fi
    if ! grep -q "$fp" opt03.s && grep -q "$fp" opt30.s; then ok "gcc backend: the last -O wins"
    else bad "gcc backend: last -O wins" "-O0 -O3 $fp=$(grep -c "$fp" opt03.s), -O3 -O0 $fp=$(grep -c "$fp" opt30.s)"; fi
    if grep -q '\.loc' optg.s && ! grep -q '\.loc' opt2.s; then ok "gcc backend: -g produces debug info, no -g does not"
    else bad "gcc backend -g" ".loc with -g: $(grep -c '\.loc' optg.s) without: $(grep -c '\.loc' opt2.s)"; fi
  else
    check "qbe backend: -O0 -O3 -g are accepted and ignored" "$nfcc" -O0 -O3 -g -c opt.c -o optq.o
  fi
  rm -f "main five.c"

  # 7. unsupported options fail loudly and write nothing
  rejects "-m32" "m32" -m32 -c util.c -o rej.o
  rejects "-fsanitize=address" "fsanitize" -fsanitize=address -c util.c -o rej.o
  rejects "-fopenmp" "fopenmp" -fopenmp -c util.c -o rej.o
  rejects "-ffast-math" "ffast-math" -ffast-math -c util.c -o rej.o
  rejects "-funsigned-char" "funsigned-char" -funsigned-char -c util.c -o rej.o
  rejects "--coverage" "coverage" --coverage -c util.c -o rej.o
  rejects "-std=c++17" "C++" -std=c++17 -c util.c -o rej.o
  rejects "-x c++" "c++" -x c++ -c util.c -o rej.o
  rejects ".cpp input" "nfcxx" -c foo.cpp -o rej.o
  rejects "unknown -f option" "fmade-up" -fmade-up-option -c util.c -o rej.o
  rejects "unknown option" "frobnicate" --frobnicate -c util.c -o rej.o
  rejects "no input" "no input" -c -o rej.o
  rejects "-MD without -c" "needs -c" -MD util.c -o rej.o
  # 7b. NFCXX_GCC_PASSTHROUGH=1 (the Linux kernel's build, docs/notes/linux-kernel.md): on the gcc backend the options
  # QBE cannot honour reach gcc, in command-line order; on the qbe backend they are still refused.
  printf 'int main(void) { char c = (char)200; return c > 0 ? 0 : 1; }\n' > uchar.c
  printf 'int g; int *p(void) { return &g; }\n' > pic.c
  if [ $b = gcc ]; then
    if NFCXX_GCC_PASSTHROUGH=1 "$nfcc" -funsigned-char uchar.c -o uchar 2>/dev/null && ./uchar; then
      ok "passthrough: -funsigned-char reaches gcc"
    else bad "passthrough: -funsigned-char reaches gcc" "char stayed signed or the compile failed"; fi
    # gcc takes the last of -fno-PIE ... -fPIC (the kernel's vDSO relies on it): no absolute 32-bit relocation
    if [ "$(uname -m)" = x86_64 ]; then
      if NFCXX_GCC_PASSTHROUGH=1 "$nfcc" -fno-PIE -mcmodel=kernel -fPIC -mcmodel=small -c pic.c -o pic.o 2>/dev/null &&
         ! readelf -rW pic.o | grep -q 'R_X86_64_32S\? '; then ok "passthrough: codegen options keep their order"
      else bad "passthrough: codegen options keep their order" "$(readelf -rW pic.o 2>&1 | grep R_X86 | head -2 | tr '\n' ' ')"; fi
    fi
  else
    NFCXX_GCC_PASSTHROUGH=1 rejects "passthrough on qbe: -funsigned-char" "funsigned-char" -funsigned-char -c util.c -o rej.o
    NFCXX_GCC_PASSTHROUGH=1 rejects "passthrough on qbe: -mno-sse" "mno-sse" -mno-sse -c util.c -o rej.o
  fi
  # 7c. NFCXX_QBE_KERNEL=1 (the qbe side of the kernel build): the kernel options the qbe path honours are accepted and
  # honoured, -mno-sse is checked, unreferenced static functions are dropped; NFCXX_QBE_TRY moves a compile to qbe only
  # when the objects match (docs/notes/linux-kernel.md)
  if [ $b = qbe ] && [ "$(uname -m)" = x86_64 ]; then
    K=(-fno-PIE -mno-red-zone -mno-sse -mno-80387 -funsigned-char -fshort-wchar -ftrivial-auto-var-init=zero)
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" uchar.c -o kuchar 2>/dev/null && ./kuchar; then ok "kernel mode: -funsigned-char honoured"
    else bad "kernel mode: -funsigned-char honoured" "char stayed signed or the compile failed"; fi
    cat > kzero.c <<'EOC'
__attribute__((noinline)) static int dirty(void) { volatile int a[64]; for (int i = 0; i < 64; i++) a[i] = 0x55; return a[7]; }
__attribute__((noinline)) static int fresh(void) { int a[64]; int s = 0; for (int i = 0; i < 64; i++) s |= a[i]; return s; }
int main(void) { dirty(); return fresh(); }
EOC
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" kzero.c -o kzero 2>/dev/null && ./kzero; then ok "kernel mode: -ftrivial-auto-var-init=zero honoured"
    else bad "kernel mode: -ftrivial-auto-var-init=zero honoured" "an uninitialized local was not zero"; fi
    printf 'double h(double x) { return x * 3; }\n' > kfp.c
    if out=$(NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" -c kfp.c -o kfp.o 2>&1); then bad "kernel mode: SSE code refused under -mno-sse" "was accepted"
    elif grep -q "SSE or x87" <<<"$out"; then ok "kernel mode: SSE code refused under -mno-sse"
    else bad "kernel mode: SSE code refused under -mno-sse" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
    printf 'extern int not_in_this_program(void);\nstatic inline int unused(void) { return not_in_this_program(); }\nint used(void) { return 1; }\n' > kinl.c
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" -c kinl.c -o kinl.o 2>/dev/null && ! nm kinl.o | grep -q not_in_this_program; then
      ok "kernel mode: unreferenced static inline functions dropped"
    else bad "kernel mode: unreferenced static inline functions dropped" "$(nm kinl.o 2>&1 | head -3 | tr '\n' ' ')"; fi
    # a dropped function's asm: its refusal is not reported and its thunk (naming a symbol the program lacks) is gone;
    # the same asm in a kept function is still refused
    cat > kasm.c <<'EOC'
extern int not_in_this_program(void);
static inline int bit(long nr) { int r; __asm__("movl %1, %0; call not_in_this_program" : "=r"(r) : "i"(1 << (nr & 7))); return r; }
static inline int named(void) { int r; __asm__("call %c1" : "=a"(r) : "i"(not_in_this_program)); return r; }
int used(int x) { __asm__("addl $1, %0" : "+r"(x)); return x; }
EOC
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" -c kasm.c -o kasm.o 2>/dev/null && ! nm kasm.o | grep -q not_in_this_program; then
      ok "kernel mode: a dropped function's asm is neither refused nor emitted"
    else bad "kernel mode: a dropped function's asm is neither refused nor emitted" "$(nm kasm.o 2>&1 | head -3 | tr '\n' ' ')"; fi
    printf 'int keep(long n) { int r; __asm__("movl %%1, %%0" : "=r"(r) : "i"(1 << (n & 7))); return r; }\n' > kasm2.c
    if out=$(NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" -c kasm2.c -o kasm2.o 2>&1); then bad "kernel mode: a kept function's unsatisfiable asm refused" "was accepted"
    elif grep -q "kasm2.c:1:.*immediate operand" <<<"$out"; then ok "kernel mode: a kept function's unsatisfiable asm refused"
    else bad "kernel mode: a kept function's unsatisfiable asm refused" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
    # file-scope asm (the kernel's EXPORT_SYMBOL): the text reaches the assembly, a section switched to and back, code
    # defined in the section a file starts in
    cat > ktop.c <<'EOC'
__asm__(".pushsection .rodata\n.globl toplevel_answer\n.balign 4\ntoplevel_answer: .long 40\n.popsection");
__asm__(".globl toplevel_two\n" "toplevel_two: movl $2, %eax\n\tret");
extern const int toplevel_answer;
int toplevel_two(void);
int main(void) { return toplevel_answer + toplevel_two(); }
EOC
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" ktop.c -o ktop 2>/dev/null && { ./ktop; [ $? = 42 ]; }; then ok "kernel mode: file-scope asm"
    else bad "kernel mode: file-scope asm" "wrong result or the compile failed"; fi
    NFCXX_QBE_KERNEL=1 rejects "kernel mode still refuses -m16" "m16" -m16 -c util.c -o rej.o
    # volatile (cproc -V): each access is a call QBE cannot merge, forward or drop -- two loads stay two, two stores stay
    # two, and a polling loop loads on every iteration; signed char loads are sign-extended
    cat > kvol.c <<'EOC'
int twice(volatile int *p) { return *p + *p; }
void two_stores(volatile long *p) { *p = 1; *p = 2; }
signed char sc(volatile signed char *p) { return *p; }
int main(void) { volatile int x = 20; volatile long y; volatile signed char c = -5; two_stores(&y); return twice(&x) + (int)y + sc(&c) + 5; }
EOC
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" -S kvol.c -o kvol.s 2>/dev/null &&
       [ "$(awk '/^twice:/,/^\.size twice/' kvol.s | grep -c 'call.*nfcxx_vload4')" = 2 ] &&
       [ "$(awk '/^two_stores:/,/^\.size two_stores/' kvol.s | grep -c 'call.*nfcxx_vstore8')" = 2 ] &&
       NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" kvol.c -o kvol 2>/dev/null && { ./kvol; [ $? = 42 ]; }; then
      ok "kernel mode: volatile accesses kept"
    else bad "kernel mode: volatile accesses kept" "$(grep -c nfcxx_v kvol.s 2>/dev/null) helper calls"; fi
    # __builtin_*_overflow lowered by cproc itself (no qbe-prep.rb in kernel mode): every type mix, against gcc's hash
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" "$root/tests/c/builtins_overflow_matrix.c" -o kov 2>/dev/null && { ./kov; [ $? = 42 ]; }; then
      ok "kernel mode: overflow built-ins match gcc for every type mix"
    else bad "kernel mode: overflow built-ins match gcc for every type mix" "wrong results or the compile failed"; fi
    if NFCXX_QBE_KERNEL=1 "$nfcc" "${K[@]}" "$root/tests/c/builtin_bitcount.c" -o kbits 2>/dev/null && { ./kbits; [ $? = 42 ]; }; then
      ok "kernel mode: bit-counting built-ins"
    else bad "kernel mode: bit-counting built-ins" "wrong results or the compile failed"; fi
    # qbe-try: an integer file moves to qbe; a file cproc cannot compile keeps the gcc object
    printf 'int sq(int a) { return a * a; }\n' > kmove.c
    printf 'int jumps(void) { __asm__ goto("jmp %%l0" : : : : out); return 1; out: return 0; }\n' > kstay.c   # asm goto: not yet
    rm -f qbe.log
    for f in kmove kstay; do
      NFCXX_BACKEND=gcc NFCXX_GCC_PASSTHROUGH=1 NFCXX_QBE_TRY='*' NFCXX_QBE_LOG=$PWD/qbe.log "$nfcc" -fno-PIE -mno-sse -c $f.c -o $f.o
    done
    if grep -q '^qbe kmove.c$' qbe.log && grep -q '^gcc kstay.c: ' qbe.log && [ -s kstay.o ]; then ok "qbe-try: moves what matches, keeps gcc otherwise"
    else bad "qbe-try: moves what matches, keeps gcc otherwise" "$(tr '\n' '|' < qbe.log)"; fi
  fi
  # an assembly source with another suffix keeps its -x language (the kernel's "-x assembler-with-cpp /dev/null" probe)
  if out=$("$nfcc" -Wa,--version -c -x assembler-with-cpp /dev/null -o /dev/null 2>&1) && grep -q "GNU assembler" <<<"$out"; then
    ok "-x assembler-with-cpp /dev/null reaches the assembler"
  else bad "-x assembler-with-cpp /dev/null reaches the assembler" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
  # -MMD on an assembly source writes the dependency file (kbuild's fixdep reads it)
  printf '#include "dep.h"\n.globl x\nx: ret\n' > depa.S; : > dep.h
  if "$nfcc" -Wp,-MMD,depa.d -c depa.S -o depa.o 2>/dev/null && grep -q 'dep\.h' depa.d; then ok "-MMD on assembly writes the dependency file"
  else bad "-MMD on assembly writes the dependency file" "no depa.d naming dep.h"; fi
  # 8. mixed-type overflow builtins (qbe-prep lowers them on the qbe backend; gcc has them natively)
  cat > mix.c <<'EOC'
int main(void) {
  int x = 7; long a; unsigned u = 4000000000u; int i;
  if (__builtin_add_overflow(x, x, &a) || a != 14) return 1;
  if (!__builtin_add_overflow(u, u, &i)) return 2;
  if (__builtin_mul_overflow(u, 2, &a) || a != 8000000000L) return 3;
  return 0;
}
EOC
  check "mixed-type __builtin_*_overflow compiles, links and is right" bash -c "'$nfcc' mix.c -o mix && ./mix"
  if [ $b = qbe ]; then   # an operand that is not an integer still must not be converted silently
    echo 'int main(void) { long a; double d = 1; return __builtin_add_overflow(d, 1, &a); }' > mixd.c
    if out=$("$nfcc" mixd.c -o mixd 2>&1); then bad "floating operand to __builtin_add_overflow" "linked"
    elif grep -q overflow_unsupported_operand_types <<<"$out"; then ok "floating operand to __builtin_add_overflow fails at link, naming the symbol"
    else bad "floating operand to __builtin_add_overflow" "$(head -2 <<<"$out" | tr '\n' ' ')"; fi
  fi
  if [ "$b" = gcc ] && [ "$(uname -m)" != x86_64 ]; then echo "skip $b -mavx2 intrinsics (x86-64 only)"; fi
  if [ "$b" = gcc ] && [ "$(uname -m)" = x86_64 ]; then
    # -mavx2 reaches the C compile, so the intrinsics inline (without it gcc: "target specific option mismatch").
    # gcc backend only: QBE ignores the ISA options and cannot compile these intrinsics.
    cat > avx2.c <<'EOF'
#include <immintrin.h>
#include <stdio.h>
__attribute__((noinline)) int f(int a, int b) {
  __m256i x = _mm256_set1_epi32(a), y = _mm256_set1_epi32(b);
  return _mm256_extract_epi32(_mm256_xor_si256(x, y), 0);
}
int main(void) { printf("%d\n", f(12, 10)); return 0; }
EOF
    if out=$("$nfcc" -mavx2 avx2.c -o avx2 2>&1) && [ "$(./avx2)" = 6 ]; then ok "-mavx2 intrinsics inline"
    else bad "-mavx2 intrinsics inline" "$(head -3 <<<"$out" | tr '\n' ' ')"; fi
  fi
  cd "$root" || exit 1
done
echo "tests/c/cc-mode: $pass passed, $fail failed"
[ $fail -eq 0 ]
