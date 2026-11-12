#!/usr/bin/env bash
# nfcc with NFCXX_BACKEND=pathb: EDG's C front end -> typed IR -> QBE (docs/notes/nfcc-pathb.md). Needs the Path B harness
# (scripts/setup-edg.sh, setup-qbe.sh, setup-pathb.sh). The default backend stays qbe: checked here too.
cd "$(dirname "$0")/../.."
root=$PWD; nfcc=$root/nfcc
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
pb() { NFCXX_BACKEND=pathb "$nfcc" "$@"; }
check() { local n=$1; shift; if out=$("$@" 2>&1); then ok "$n"; else bad "$n" "$(head -3 <<<"$out" | tr '\n' ' ')"; fi; }
# refuses NAME REGEX CMD...: CMD fails (non-zero) and its message matches REGEX
refuses() { local n=$1 re=$2; shift 2; local rc=0; out=$("$@" 2>&1) || rc=$?
  if [ $rc != 0 ] && grep -q -- "$re" <<<"$out"; then ok "$n"; else bad "$n" "rc=$rc: $(head -2 <<<"$out" | tr '\n' ' ')"; fi; }

mkdir -p "$tmp/inc"
printf '#define FROM_INC 30\n' > "$tmp/inc/h.h"
cat > "$tmp/a.c" <<'EOF2'
#include "h.h"
int add(int a, int b) { return a + b + FROM_INC + EXTRA; }
EOF2
cat > "$tmp/main.c" <<'EOF2'
#include <stdio.h>
int add(int, int);
int main(void) { printf("%d\n", add(1, 1)); return 0; }
EOF2

check "-c -I -D" pb -c -O2 -g -Wall -fPIC -I"$tmp/inc" -DEXTRA=10 "$tmp/a.c" -o "$tmp/a.o"
[ -f "$tmp/a.o" ] && ok "object written" || bad "object written" missing
check "link .o and .c, run" pb "$tmp/a.o" "$tmp/main.c" -lm -o "$tmp/prog"
[ "$("$tmp/prog" 2>&1)" = 42 ] && ok "program prints 42" || bad "program prints 42" "$("$tmp/prog" 2>&1)"
check "-I DIR -D X (separate arguments), -std=gnu11" pb -std=gnu11 -c -I "$tmp/inc" -D EXTRA=1 "$tmp/a.c" -o "$tmp/b.o"
check "-S" pb -S -I"$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/a.s"
grep -q 'add' "$tmp/a.s" 2>/dev/null && ok "-S writes assembly naming add" || bad "-S writes assembly" "$(head -2 "$tmp/a.s" 2>&1)"
check "-MD -MF with -c" pb -c -I"$tmp/inc" -DEXTRA=1 -MD -MF "$tmp/a.d" "$tmp/a.c" -o "$tmp/c.o"
grep -q 'inc/h.h' "$tmp/a.d" 2>/dev/null && ok "dependency file lists the header" || bad "dependency file" "$(cat "$tmp/a.d" 2>&1)"
check "-E goes to the host preprocessor" pb -E -I"$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/a.i"
grep -q 'return a + b + 30 + 1' "$tmp/a.i" && ok "-E output" || bad "-E output" "$(tail -2 "$tmp/a.i")"
check "--version names the backend" bash -c "NFCXX_BACKEND=pathb '$nfcc' --version | grep -q pathb"

# Kernel-style inline asm (x86-64 only): asm goto, "i" operands that are constants after inlining, a "m" operand of a const
# object, alternatives sections. The exit code is gcc's (tests/c/inline_asm_kernel_alt.c: EXPECT 42; the plain qbe backend
# cannot build it, its XFAIL-qbe marker says why); inline_asm_goto.c is the same asm goto family without inlining.
if [ "$(uname -m)" = x86_64 ]; then
  for t in inline_asm_kernel_alt inline_asm_goto; do
    src=$root/tests/c/$t.c
    cc -O2 -fwrapv "$src" -o "$tmp/$t.gcc" 2>/dev/null; "$tmp/$t.gcc" >/dev/null 2>&1; want=$?
    if out=$(pb "$src" -o "$tmp/$t.pb" 2>&1); then
      "$tmp/$t.pb" >/dev/null 2>&1; got=$?
      [ "$got" = "$want" ] && ok "asm $t: exit $got as gcc's" || bad "asm $t" "want $want got $got"
    else
      bad "asm $t" "build: $(grep -m1 -E 'refused|not emitted|error' <<<"$out" | cut -c1-200)"
    fi
  done
fi

# -fPIC / -shared: a shared object whose code takes the address of an exported function and of an exported and an extern
# data object (PC-relative references to these are not allowed in a shared object: ld "can not be used when making a
# shared object"). The code store of ASTro's calc is such an object (tests/realworld/run_astro.sh); here a dlopen'ed one.
cat > "$tmp/so.c" <<'EOF2'
extern int host_counter;
int so_counter = 5;
static int local_fn(int x) { return x + 1; }
int exported_fn(int x) { return x * 2; }
typedef int (*fn_t)(int);
fn_t so_get_exported(void) { return exported_fn; }
fn_t so_get_local(void) { return local_fn; }
int *so_counter_addr(void) { return &so_counter; }
int *host_counter_addr(void) { return &host_counter; }
int so_bump(void) { host_counter += so_counter; return host_counter; }
EOF2
cat > "$tmp/somain.c" <<'EOF2'
#include <dlfcn.h>
#include <stdio.h>
int host_counter = 10;
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { puts(dlerror()); return 1; }
  typedef int (*fn_t)(int);
  fn_t (*ge)(void) = (fn_t (*)(void))dlsym(h, "so_get_exported");
  fn_t (*gl)(void) = (fn_t (*)(void))dlsym(h, "so_get_local");
  int *(*sc)(void) = (int *(*)(void))dlsym(h, "so_counter_addr");
  int *(*hc)(void) = (int *(*)(void))dlsym(h, "host_counter_addr");
  int (*bump)(void) = (int (*)(void))dlsym(h, "so_bump");
  int r = ge()(4) * 100 + gl()(4) * 10 + (*sc() == 5) + 1000 * (hc() == &host_counter) + 10000 * (bump() == 15);
  printf("%d\n", r);
  return 0;
}
EOF2
if check "shared object (-shared -fPIC)" pb -shared -fPIC "$tmp/so.c" -o "$tmp/so.so" && check "host for the shared object" pb "$tmp/somain.c" -rdynamic -ldl -o "$tmp/somain"; then
  [ "$("$tmp/somain" "$tmp/so.so" 2>&1)" = 11851 ] && ok "dlopen: addresses of exported, static, extern data and a function read through the GOT" ||
    bad "dlopen of the shared object" "$("$tmp/somain" "$tmp/so.so" 2>&1)"
fi

# gcc's default dialect is gnu17: glibc's _DEFAULT_SOURCE (clock_gettime and CLOCK_MONOTONIC, ssize_t from <stdint.h>-only
# code, the POSIX.1-2008 declarations) is on without a -D. EDG's C mode defines _POSIX_SOURCE only, which turns the implied
# default off; nfcc adds -D_DEFAULT_SOURCE for the gnu dialects (ASTro's runtime/precise_gc/gc.h needs both names).
cat > "$tmp/posix.c" <<'EOF2'
#include <time.h>
#include <sys/types.h>
ssize_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (ssize_t)t.tv_nsec; }
EOF2
check "default dialect: CLOCK_MONOTONIC and clock_gettime" pb -c "$tmp/posix.c" -o "$tmp/posix.o"
check "-std=gnu11: the same" pb -std=gnu11 -c "$tmp/posix.c" -o "$tmp/posix.o"

# A static function stays local to its object file: two translation units each define one of the same name (a recursive one
# is not inlined away), and the link has no duplicate symbol.
cat > "$tmp/st1.c" <<'EOF2'
static int depth(int x) { return x ? depth(x - 1) + 1 : 0; }
int one(int x) { return depth(x); }
EOF2
cat > "$tmp/st2.c" <<'EOF2'
#include <stdio.h>
static int depth(int x) { return x ? depth(x - 1) + 2 : 0; }
int one(int);
int main(void) { printf("%d\n", one(5) * 100 + depth(5)); return 0; }
EOF2
if check "two files with a static function of one name: link" pb "$tmp/st1.c" "$tmp/st2.c" -o "$tmp/st"; then
  [ "$("$tmp/st" 2>&1)" = 510 ] && ok "each file calls its own static function" || bad "static functions of one name" "$("$tmp/st" 2>&1)"
fi

# Options Path B cannot honour are refused with a message and a non-zero status, not ignored
refuses "-isystem refused" "isystem.*pathb backend" pb -c -isystem "$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/x.o"
refuses "-nostdinc refused" "nostdinc.*pathb backend" pb -c -nostdinc "$tmp/a.c" -o "$tmp/x.o"
refuses "-Wa,* refused" "Wa.*pathb backend" pb -c -Wa,--noexecstack "$tmp/a.c" -o "$tmp/x.o"
refuses "-funsigned-char refused" "funsigned-char" pb -c -funsigned-char "$tmp/a.c" -o "$tmp/x.o"
refuses "-fsanitize refused" "fsanitize" pb -c -fsanitize=address "$tmp/a.c" -o "$tmp/x.o"
refuses "-m32 refused" "m32" pb -c -m32 "$tmp/a.c" -o "$tmp/x.o"
refuses "C++ refused" "C++" pb -c -x c++ "$tmp/a.c" -o "$tmp/x.o"
refuses "unknown backend refused" "unknown NFCXX_BACKEND" env NFCXX_BACKEND=nope "$nfcc" -c "$tmp/a.c"

# The default stays qbe
if [ -x "$root/build/cproc/cproc-qbe" ]; then
  out=$("$nfcc" --version); grep -q 'backend qbe' <<<"$out" && ok "default backend is qbe" || bad "default backend is qbe" "$out"
fi
echo "nfcc pathb: $pass passed, $fail failed"
[ $fail = 0 ]
