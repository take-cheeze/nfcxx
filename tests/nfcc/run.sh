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
