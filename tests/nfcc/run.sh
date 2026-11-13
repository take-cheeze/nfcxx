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
# gnu modes (the default, -std=gnu99): glibc's POSIX names are visible as with gcc (EDG's gcc mode defines __STRICT_ANSI__, which hides
# struct stat's st_atim); -std=c99 hides them, as gcc's does (mruby's hal-posix-io reads st_atim in its gnu99 build).
cat > "$tmp/st.c" <<'EOF2'
#include <sys/stat.h>
long f(const struct stat *s) { return (long)s->st_atim.tv_sec; }
EOF2
check "gnu99 sees st_atim" pb -std=gnu99 -c "$tmp/st.c" -o "$tmp/st.o"
check "default mode sees st_atim" pb -c "$tmp/st.c" -o "$tmp/st2.o"
refuses "-std=c99 hides st_atim (as gcc)" "st_atim" pb -std=c99 -c "$tmp/st.c" -o "$tmp/st3.o"
# A static function has internal linkage: two objects define `helper`, and the link finds one symbol each (mruby's libmruby has a static
# inline mrb_type in every unit).
printf 'static int helper(int x) { return x + 1; }\nint a_val(void) { return helper(1); }\n' > "$tmp/s1.c"
printf 'static int helper(int x) { return x + 10; }\nint a_val(void);\nint main(void) { return a_val() == 2 && helper(1) == 11 ? 0 : 1; }\n' > "$tmp/s2.c"
check "two objects with the same static function" pb -c "$tmp/s1.c" -o "$tmp/s1.o"
check "second object" pb -c "$tmp/s2.c" -o "$tmp/s2.o"
check "link them (no multiple definition)" pb "$tmp/s1.o" "$tmp/s2.o" -o "$tmp/s12"
"$tmp/s12" && ok "static helpers stay apart" || bad "static helpers stay apart" "rc=$?"
# Path B only (no gcc fallback in nfcc): shapes the SSA route refused or got wrong are built here and run, and the exit code is gcc's.
for t in int_plus_pointer variadic_struct_return_byval static_const_struct_padding; do
  src=$root/tests/c/$t.c
  if out=$(pb "$src" -o "$tmp/$t.pb" 2>&1); then
    "$tmp/$t.pb" >/dev/null 2>&1; got=$?
    [ "$got" = 0 ] && ok "$t: exit 0 as gcc's" || bad "$t" "want 0 got $got"
  else
    bad "$t" "build: $(grep -m1 -E 'refused|not emitted|error|invalid' <<<"$out" | cut -c1-200)"
  fi
done
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


# The kernel's option set (docs/notes/linux-kernel.md). -nostdinc, -isystem and -idirafter are the include path of Path B's front end;
# -funsigned-char, -fshort-wchar and -ffreestanding are honoured by it; -mno-sse is checked on the assembly; options with no effect on
# QBE's code are dropped. An option that changes meaning and that Path B cannot honour sends the compile to gcc (never dropped).
# NFCXX_PATHB_LOG says which one made a compile: "pathb SRC" or "gcc SRC: reason".
export NFCXX_PATHB_LOG=$tmp/log
used() { grep -F "/$2" "$tmp/log" | tail -1 | grep -q "^$1 "; }   # used pathb|gcc SRC: the last compile of SRC went to that one
# pbrun NAME EXPECTED-EXIT SRC OPTION...: build SRC on Path B with OPTION... and run it; its exit status, and gcc's with the same options, is EXPECTED-EXIT
pbrun() {
  local n=$1 want=$2 src=$3 got gotg; shift 3
  if ! out=$(pb "$@" "$src" -o "$tmp/run.pb" 2>&1); then bad "$n" "build: $(head -2 <<<"$out" | tr '\n' ' ')"; return; fi
  "$tmp/run.pb" >/dev/null 2>&1; got=$?
  if cc -O2 -fwrapv "$@" "$src" -o "$tmp/run.gcc" 2>/dev/null; then "$tmp/run.gcc" >/dev/null 2>&1; gotg=$?; else gotg=$want; fi
  if [ "$got" = "$want" ] && [ "$gotg" = "$want" ]; then ok "$n"; else bad "$n" "pathb exit $got, gcc exit $gotg, want $want"; fi
}
gccinc=$(cc -print-file-name=include)
mkdir -p "$tmp/sysinc" "$tmp/after"
printf 'int fake_stdio_h = 5;\n' > "$tmp/sysinc/stdio.h"
printf '#define FROM_AFTER 4\n' > "$tmp/after/after.h"
printf '#include <stdio.h>\nint use(void) { return 1; }\n' > "$tmp/sys.c"
printf '#include <h.h>\nint v = FROM_INC;\n' > "$tmp/isys.c"
printf '#include <after.h>\nint v = FROM_AFTER;\n' > "$tmp/aft.c"
printf '#include <stdarg.h>\nint f(int n, ...) { va_list ap; va_start(ap, n); int v = va_arg(ap, int); va_end(ap); return v; }\n' > "$tmp/va.c"
refuses "-nostdinc: the host's system headers are gone" "stdio.h" pb -c -nostdinc "$tmp/sys.c" -o "$tmp/x.o"
check "-nostdinc -isystem DIR: DIR is the system path" pb -c -nostdinc -isystem "$tmp/sysinc" "$tmp/sys.c" -o "$tmp/ns.o"
nm "$tmp/ns.o" 2>/dev/null | grep -q fake_stdio_h && ok "-isystem's stdio.h is the one read" || bad "-isystem's stdio.h is the one read" "$(nm "$tmp/ns.o" 2>&1 | head -3)"
check "-isystem DIR (without -nostdinc)" pb -c -isystem "$tmp/sysinc" "$tmp/sys.c" -o "$tmp/is.o"
nm "$tmp/is.o" 2>/dev/null | grep -q fake_stdio_h && ok "-isystem DIR is searched before the host's <stdio.h>" || bad "-isystem DIR before the host's <stdio.h>" "fake_stdio_h is missing"
check "-isystemDIR (joined)" pb -c -isystem"$tmp/inc" "$tmp/isys.c" -o "$tmp/is2.o"
check "-idirafter DIR" pb -c -idirafter "$tmp/after" "$tmp/aft.c" -o "$tmp/af.o"
check "-nostdinc -isystem gcc's include directory: <stdarg.h>" pb -c -nostdinc -isystem "$gccinc" "$tmp/va.c" -o "$tmp/va.o"
used pathb va.c && ok "the -nostdinc compile is Path B's" || bad "the -nostdinc compile is Path B's" "$(tail -1 "$tmp/log")"

# -funsigned-char / -fsigned-char: the signedness of plain char, in the code and in the macros
cat > "$tmp/uc.c" <<'EOF2'
#include <limits.h>
char buf[2] = { (char)200, 0 };
int main(void) {
  int neg = buf[0] < 0;                    /* signed: 1 */
  int wide = buf[0];                       /* signed: -56, unsigned: 200 */
  int mn = CHAR_MIN;                       /* signed: -128 */
#ifdef __CHAR_UNSIGNED__
  int m = 1;
#else
  int m = 0;
#endif
  return neg * 1 + (wide == 200) * 2 + (mn == 0) * 4 + m * 8;
}
EOF2
pbrun "default: char is signed" 1 "$tmp/uc.c"
pbrun "-funsigned-char" 14 "$tmp/uc.c" -funsigned-char
pbrun "-fno-signed-char" 14 "$tmp/uc.c" -fno-signed-char
pbrun "-funsigned-char -fsigned-char: the last one wins" 1 "$tmp/uc.c" -funsigned-char -fsigned-char
pb -c -funsigned-char "$tmp/uc.c" -o "$tmp/x.o" 2>/dev/null && used pathb uc.c && ok "-funsigned-char is compiled by Path B, not gcc" || bad "-funsigned-char is compiled by Path B" "$(tail -1 "$tmp/log")"

# -fshort-wchar: the headers' wchar_t is unsigned short; a wide literal needs gcc (EDG types it as int)
cat > "$tmp/ww.c" <<'EOF2'
#include <stddef.h>
#include <wchar.h>
int main(void) { return (int)sizeof(wchar_t) * 10 + (WCHAR_MAX == 0xffff) + 2 * (WCHAR_MIN == 0); }
EOF2
printf '#include <stddef.h>\nint main(void) { return (int)sizeof(L"ab") * 10 + (int)sizeof(wchar_t); }\n' > "$tmp/wl.c"
pbrun "default: wchar_t is int" 40 "$tmp/ww.c"
pbrun "-fshort-wchar: wchar_t is 2 bytes, WCHAR_MAX is 0xffff" 23 "$tmp/ww.c" -fshort-wchar
used pathb ww.c && ok "-fshort-wchar without a wide literal: Path B" || bad "-fshort-wchar without a wide literal: Path B" "$(tail -1 "$tmp/log")"
pbrun "-fshort-wchar with a wide literal: gcc's result" 62 "$tmp/wl.c" -fshort-wchar
used gcc wl.c && tail -1 "$tmp/log" | grep -q "wide" && ok "-fshort-wchar with a wide literal went to gcc, and the log says why" || bad "-fshort-wchar with a wide literal went to gcc" "$(tail -1 "$tmp/log")"

# -ffreestanding: __STDC_HOSTED__ is 0
printf 'int main(void) { return __STDC_HOSTED__; }\n' > "$tmp/fs.c"
pbrun "hosted by default" 1 "$tmp/fs.c"
pbrun "-ffreestanding: __STDC_HOSTED__ is 0" 0 "$tmp/fs.c" -ffreestanding

# Options with no effect on QBE's code are dropped: Path B builds it
check "the kernel's codegen options" pb -c -mno-red-zone -mcmodel=kernel -mno-mmx -mno-3dnow -mno-avx -mpreferred-stack-boundary=3 -mskip-rax-setup \
  -mtune=generic -fno-PIE -fno-stack-protector -fno-jump-tables -fno-delete-null-pointer-checks -fno-strict-overflow -fno-strict-aliasing -fwrapv \
  -fno-common -fno-allow-store-data-races -fno-optimize-sibling-calls -fno-function-sections -fno-data-sections -fconserve-stack \
  -fno-stack-clash-protection -fcf-protection=none -fstrict-flex-arrays=3 -falign-functions=16 -fno-asynchronous-unwind-tables -Wall -O2 -g -pipe \
  "$tmp/uc.c" -o "$tmp/k.o"
used pathb uc.c && ok "the kernel's codegen options did not move the compile to gcc" || bad "the kernel's codegen options" "$(tail -1 "$tmp/log")"
printf 'int g(int);\nint f(int a) { return g(a) + 1; }\n' > "$tmp/cf.c"
pb -S "$tmp/cf.c" -o "$tmp/cf.s" 2>/dev/null; grep -q '\.cfi_' "$tmp/cf.s" && ok "default: .cfi directives" || bad "default: .cfi directives" "none"
pb -S -fno-asynchronous-unwind-tables "$tmp/cf.c" -o "$tmp/cf2.s" 2>/dev/null
[ -s "$tmp/cf2.s" ] && ! grep -q '\.cfi_' "$tmp/cf2.s" && ok "-fno-asynchronous-unwind-tables: no .cfi directives (qbe -U)" || bad "-fno-asynchronous-unwind-tables: no .cfi" "$(grep -m2 cfi "$tmp/cf2.s")"

# -mno-sse: checked on the assembly (QBE has no switch): integer code passes, SSE code is refused
printf 'long f(long a, long b) { return a * b + (a >> 3); }\nlong m(long *p, long *q) { long t = *p; *p = *q; *q = t; return t; }\n' > "$tmp/int.c"
printf 'double d(double x) { return x * 2.0; }\n' > "$tmp/fp.c"
check "-mno-sse: integer code builds" pb -c -mno-sse -mno-sse2 -mno-80387 "$tmp/int.c" -o "$tmp/nsse.o"
objdump -d "$tmp/nsse.o" | grep -qE '%[xyz]mm|%st' && bad "-mno-sse: no SSE in the object" "found" || ok "-mno-sse: no SSE in the object"
used pathb int.c && ok "-mno-sse: the integer code is Path B's" || bad "-mno-sse: Path B" "$(tail -1 "$tmp/log")"
refuses "-mno-sse: SSE code is refused" "mno-sse" pb -c -mno-sse "$tmp/fp.c" -o "$tmp/x.o"
refuses "-mno-80387: SSE code is refused too" "SSE or x87" pb -c -mno-80387 "$tmp/fp.c" -o "$tmp/x.o"
check "the same code builds without -mno-sse" pb -c "$tmp/fp.c" -o "$tmp/x.o"

# Options that change meaning and that Path B cannot honour: the compile is gcc's, with the option; nothing is dropped
printf 'enum e { A, B };\nint main(void) { return (int)sizeof(enum e); }\n' > "$tmp/en.c"
pbrun "-fshort-enums: the enum is 1 byte" 1 "$tmp/en.c" -fshort-enums
used gcc en.c && ok "-fshort-enums went to gcc" || bad "-fshort-enums went to gcc" "$(tail -1 "$tmp/log")"
pbrun "no option: the enum is 4 bytes, Path B" 4 "$tmp/en.c"
used pathb en.c && ok "without -fshort-enums Path B builds it" || bad "without -fshort-enums Path B builds it" "$(tail -1 "$tmp/log")"
check "-m16 compiles with gcc" pb -c -m16 "$tmp/int.c" -o "$tmp/m16.o"
used gcc int.c && ok "-m16 went to gcc" || bad "-m16 went to gcc" "$(tail -1 "$tmp/log")"
file -b "$tmp/m16.o" | grep -q 'ELF 32-bit' && ok "-m16: the object is i386 (the option reached gcc)" || bad "-m16: the object is i386" "$(file -b "$tmp/m16.o")"
check "-ftrivial-auto-var-init=zero compiles with gcc" pb -c -ftrivial-auto-var-init=zero "$tmp/int.c" -o "$tmp/tz.o"
used gcc int.c && ok "-ftrivial-auto-var-init=zero went to gcc" || bad "-ftrivial-auto-var-init=zero went to gcc" "$(tail -1 "$tmp/log")"
check "-iquote compiles with gcc" pb -c -iquote "$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/iq.o"
used gcc a.c && ok "-iquote went to gcc" || bad "-iquote went to gcc" "$(tail -1 "$tmp/log")"
check "-Wa,* compiles with gcc" pb -c -Wa,--noexecstack -I"$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/wa.o"
used gcc a.c && ok "-Wa,* went to gcc" || bad "-Wa,* went to gcc" "$(tail -1 "$tmp/log")"
refuses "an option gcc does not know is gcc's error" "unrecognized\|unknown" pb -c -fno-such-option "$tmp/int.c" -o "$tmp/x.o"
# a compile that Path B itself refuses moves to gcc only when asked (NFCXX_PATHB_FALLBACK=gcc)
printf 'typedef int v4 __attribute__((vector_size(16)));\nv4 f(v4 a, v4 b) { return a + b; }\n' > "$tmp/vec.c"   # a vector type: Path B has none
if ! pb -c "$tmp/vec.c" -o "$tmp/x.o" >/dev/null 2>&1; then
  ok "a unit Path B refuses fails without NFCXX_PATHB_FALLBACK"
  NFCXX_PATHB_FALLBACK=gcc pb -c "$tmp/vec.c" -o "$tmp/fb.o" >/dev/null 2>&1 && tail -1 "$tmp/log" | grep -q '^gcc .*Path B refused' &&
    ok "NFCXX_PATHB_FALLBACK=gcc: gcc builds it, the log says why" || bad "NFCXX_PATHB_FALLBACK=gcc" "$(tail -1 "$tmp/log")"
else bad "vec.c is refused by Path B (the fallback test's input)" "it builds now: use another unit"; fi
# the instrumentation options stay refused: gcc would instrument, QBE's output would not
refuses "-fsanitize refused" "fsanitize" pb -c -fsanitize=address "$tmp/a.c" -o "$tmp/x.o"
refuses "C++ refused" "C++" pb -c -x c++ "$tmp/a.c" -o "$tmp/x.o"
refuses "unknown backend refused" "unknown NFCXX_BACKEND" env NFCXX_BACKEND=nope "$nfcc" -c "$tmp/a.c"

# A global register variable bound to rsp (the kernel's current_stack_pointer, ASM_CALL_CONSTRAINT) is the register: no symbol is
# defined or referenced (the kernel's link would have an undefined reference), reads are rsp, and the "+r" operand is dropped.
cat > "$tmp/rsp.c" <<'EOF2'
register unsigned long current_stack_pointer asm("rsp");
extern void ext(void);
unsigned long f(void) { ext(); asm volatile("" : "+r"(current_stack_pointer) : : "memory"); return 1; }
unsigned long g(void) { return current_stack_pointer & ~0xfffUL; }
EOF2
check "a global register variable on rsp builds" pb -c -mno-sse -mno-red-zone "$tmp/rsp.c" -o "$tmp/rsp.o"
used pathb rsp.c && ok "the rsp register variable compile is Path B's" || bad "the rsp register variable compile is Path B's" "$(tail -1 "$tmp/log")"
nm "$tmp/rsp.o" | grep -q current_stack_pointer && bad "the rsp register variable has no symbol" "$(nm "$tmp/rsp.o" | grep current_stack_pointer)" || ok "the rsp register variable has no symbol (not defined, not undefined)"
cp "$root/tests/c/global_register_sp.c" "$tmp/gr.c"
check "the rsp register variable program links with no current_stack_pointer" pb "$tmp/gr.c" -o "$tmp/gr"
"$tmp/gr"; [ $? = 42 ] && ok "the rsp register variable program runs (reads and asm operands)" || bad "the rsp register variable program runs" "exit $?"

# A unit with no hosted libc (-ffreestanding, -nostdinc, -mno-sse: the kernel) must not reference abort: a failed check (division
# by zero, a shift out of range) is the trap instruction. A hosted unit keeps the abort call (SIGABRT).
printf 'int d(int a, int b) { return a / b; }\nint sh(int a, int b) { return a << b; }\n' > "$tmp/chk.c"
check "a checked division and shift build" pb -c "$tmp/chk.c" -o "$tmp/chk.o"
nm "$tmp/chk.o" | grep -q ' U abort' && ok "hosted: a failed check calls abort" || bad "hosted: a failed check calls abort" "$(nm "$tmp/chk.o" | tr '\n' ' ')"
for o in -ffreestanding -mno-sse -nostdinc; do
  check "$o: the checks build" pb -c $o "$tmp/chk.c" -o "$tmp/chkf.o"
  nm "$tmp/chkf.o" | grep -qE '\babort\b|pathb_check' && bad "$o: no abort and no pathb_check" "$(nm "$tmp/chkf.o" | tr '\n' ' ')" || ok "$o: no abort and no pathb_check"
  objdump -d "$tmp/chkf.o" | grep -q ud2 && ok "$o: a failed check is ud2" || bad "$o: a failed check is ud2" "no ud2"
done

# __attribute__((used)) on a static function keeps it though nothing refers to it (the kernel's asm-offsets.c: `static void __used
# common(void)`, whose asm statements kbuild reads from the assembly), and a weak definition is weak in the object, is kept though
# unreferenced, and is not inlined (another object's strong definition overrides it: the kernel's `__weak sched_clock`).
cat > "$tmp/uw.c" <<'EOF2'
static void __attribute__((used)) common(void) { asm volatile("\n.ascii \"->MARK %0\"" : : "i"(5)); }
static int __attribute__((unused)) dropped(void) { return 3; }
int __attribute__((weak)) wf(void) { return 1; }
int __attribute__((weak)) wv = 3;
int caller(void) { return wf() + 1; }
EOF2
check "a static used function and weak definitions build" pb -c "$tmp/uw.c" -o "$tmp/uw.o"
nm "$tmp/uw.o" | grep -q ' t common$' && ok "the static used function is kept" || bad "the static used function is kept" "$(nm "$tmp/uw.o" | tr '\n' ' ')"
nm "$tmp/uw.o" | grep -q ' t dropped$' && bad "an unused static function without used is dropped" "kept" || ok "an unused static function without used is dropped"
nm "$tmp/uw.o" | grep -q ' W wf$' && ok "the weak function is weak in the object" || bad "the weak function is weak in the object" "$(nm "$tmp/uw.o" | tr '\n' ' ')"
nm "$tmp/uw.o" | grep -q ' V wv$' && ok "the weak variable is weak in the object" || bad "the weak variable is weak in the object" "$(nm "$tmp/uw.o" | tr '\n' ' ')"
objdump -dr "$tmp/uw.o" | grep -A8 '<caller>:' | grep -q 'wf' && ok "the weak function is called, not inlined" || bad "the weak function is called, not inlined" "no call of wf in caller"

# __attribute__((always_inline)) is inlined whatever the callee's size (the inliner's --max-callee does not apply to it), so no
# out-of-line copy remains (the kernel's `static __always_inline __init` helpers: a copy in .text would read .init.rodata).
{
  echo 'extern int ext(int);'
  echo 'static inline __attribute__((always_inline)) int big(int i) {'
  echo '  int s = 0;'
  echo '  s += ext(i + 0) * 2 + ext(s ^ 0);'
  echo '  s += ext(i + 1) * 3 + ext(s ^ 1);'
  echo '  s += ext(i + 2) * 4 + ext(s ^ 2);'
  echo '  s += ext(i + 3) * 5 + ext(s ^ 3);'
  echo '  s += ext(i + 4) * 6 + ext(s ^ 4);'
  echo '  s += ext(i + 5) * 7 + ext(s ^ 5);'
  echo '  s += ext(i + 6) * 8 + ext(s ^ 6);'
  echo '  s += ext(i + 7) * 9 + ext(s ^ 7);'
  echo '  s += ext(i + 8) * 10 + ext(s ^ 8);'
  echo '  s += ext(i + 9) * 11 + ext(s ^ 9);'
  echo '  s += ext(i + 10) * 12 + ext(s ^ 10);'
  echo '  s += ext(i + 11) * 13 + ext(s ^ 11);'
  echo '  s += ext(i + 12) * 14 + ext(s ^ 12);'
  echo '  s += ext(i + 13) * 15 + ext(s ^ 13);'
  echo '  s += ext(i + 14) * 16 + ext(s ^ 14);'
  echo '  s += ext(i + 15) * 17 + ext(s ^ 15);'
  echo '  s += ext(i + 16) * 18 + ext(s ^ 16);'
  echo '  s += ext(i + 17) * 19 + ext(s ^ 17);'
  echo '  s += ext(i + 18) * 20 + ext(s ^ 18);'
  echo '  s += ext(i + 19) * 21 + ext(s ^ 19);'
  echo '  s += ext(i + 20) * 22 + ext(s ^ 20);'
  echo '  s += ext(i + 21) * 23 + ext(s ^ 21);'
  echo '  s += ext(i + 22) * 24 + ext(s ^ 22);'
  echo '  s += ext(i + 23) * 25 + ext(s ^ 23);'
  echo '  s += ext(i + 24) * 26 + ext(s ^ 24);'
  echo '  s += ext(i + 25) * 27 + ext(s ^ 25);'
  echo '  s += ext(i + 26) * 28 + ext(s ^ 26);'
  echo '  s += ext(i + 27) * 29 + ext(s ^ 27);'
  echo '  s += ext(i + 28) * 30 + ext(s ^ 28);'
  echo '  s += ext(i + 29) * 31 + ext(s ^ 29);'
  echo '  s += ext(i + 30) * 32 + ext(s ^ 30);'
  echo '  s += ext(i + 31) * 33 + ext(s ^ 31);'
  echo '  s += ext(i + 32) * 34 + ext(s ^ 32);'
  echo '  s += ext(i + 33) * 35 + ext(s ^ 33);'
  echo '  s += ext(i + 34) * 36 + ext(s ^ 34);'
  echo '  s += ext(i + 35) * 37 + ext(s ^ 35);'
  echo '  s += ext(i + 36) * 38 + ext(s ^ 36);'
  echo '  s += ext(i + 37) * 39 + ext(s ^ 37);'
  echo '  s += ext(i + 38) * 40 + ext(s ^ 38);'
  echo '  s += ext(i + 39) * 41 + ext(s ^ 39);'
  echo '  s += ext(i + 40) * 42 + ext(s ^ 40);'
  echo '  s += ext(i + 41) * 43 + ext(s ^ 41);'
  echo '  s += ext(i + 42) * 44 + ext(s ^ 42);'
  echo '  s += ext(i + 43) * 45 + ext(s ^ 43);'
  echo '  s += ext(i + 44) * 46 + ext(s ^ 44);'
  echo '  s += ext(i + 45) * 47 + ext(s ^ 45);'
  echo '  s += ext(i + 46) * 48 + ext(s ^ 46);'
  echo '  s += ext(i + 47) * 49 + ext(s ^ 47);'
  echo '  s += ext(i + 48) * 50 + ext(s ^ 48);'
  echo '  s += ext(i + 49) * 51 + ext(s ^ 49);'
  echo '  s += ext(i + 50) * 52 + ext(s ^ 50);'
  echo '  s += ext(i + 51) * 53 + ext(s ^ 51);'
  echo '  s += ext(i + 52) * 54 + ext(s ^ 52);'
  echo '  s += ext(i + 53) * 55 + ext(s ^ 53);'
  echo '  s += ext(i + 54) * 56 + ext(s ^ 54);'
  echo '  s += ext(i + 55) * 57 + ext(s ^ 55);'
  echo '  s += ext(i + 56) * 58 + ext(s ^ 56);'
  echo '  s += ext(i + 57) * 59 + ext(s ^ 57);'
  echo '  s += ext(i + 58) * 60 + ext(s ^ 58);'
  echo '  s += ext(i + 59) * 61 + ext(s ^ 59);'
  echo '  return s;'
  echo '}'
  echo 'static inline int big2(int i) {'
  echo '  int s = 0;'
  echo '  s += ext(i + 0) * 2 + ext(s ^ 0);'
  echo '  s += ext(i + 1) * 3 + ext(s ^ 1);'
  echo '  s += ext(i + 2) * 4 + ext(s ^ 2);'
  echo '  s += ext(i + 3) * 5 + ext(s ^ 3);'
  echo '  s += ext(i + 4) * 6 + ext(s ^ 4);'
  echo '  s += ext(i + 5) * 7 + ext(s ^ 5);'
  echo '  s += ext(i + 6) * 8 + ext(s ^ 6);'
  echo '  s += ext(i + 7) * 9 + ext(s ^ 7);'
  echo '  s += ext(i + 8) * 10 + ext(s ^ 8);'
  echo '  s += ext(i + 9) * 11 + ext(s ^ 9);'
  echo '  s += ext(i + 10) * 12 + ext(s ^ 10);'
  echo '  s += ext(i + 11) * 13 + ext(s ^ 11);'
  echo '  s += ext(i + 12) * 14 + ext(s ^ 12);'
  echo '  s += ext(i + 13) * 15 + ext(s ^ 13);'
  echo '  s += ext(i + 14) * 16 + ext(s ^ 14);'
  echo '  s += ext(i + 15) * 17 + ext(s ^ 15);'
  echo '  s += ext(i + 16) * 18 + ext(s ^ 16);'
  echo '  s += ext(i + 17) * 19 + ext(s ^ 17);'
  echo '  s += ext(i + 18) * 20 + ext(s ^ 18);'
  echo '  s += ext(i + 19) * 21 + ext(s ^ 19);'
  echo '  s += ext(i + 20) * 22 + ext(s ^ 20);'
  echo '  s += ext(i + 21) * 23 + ext(s ^ 21);'
  echo '  s += ext(i + 22) * 24 + ext(s ^ 22);'
  echo '  s += ext(i + 23) * 25 + ext(s ^ 23);'
  echo '  s += ext(i + 24) * 26 + ext(s ^ 24);'
  echo '  s += ext(i + 25) * 27 + ext(s ^ 25);'
  echo '  s += ext(i + 26) * 28 + ext(s ^ 26);'
  echo '  s += ext(i + 27) * 29 + ext(s ^ 27);'
  echo '  s += ext(i + 28) * 30 + ext(s ^ 28);'
  echo '  s += ext(i + 29) * 31 + ext(s ^ 29);'
  echo '  s += ext(i + 30) * 32 + ext(s ^ 30);'
  echo '  s += ext(i + 31) * 33 + ext(s ^ 31);'
  echo '  s += ext(i + 32) * 34 + ext(s ^ 32);'
  echo '  s += ext(i + 33) * 35 + ext(s ^ 33);'
  echo '  s += ext(i + 34) * 36 + ext(s ^ 34);'
  echo '  s += ext(i + 35) * 37 + ext(s ^ 35);'
  echo '  s += ext(i + 36) * 38 + ext(s ^ 36);'
  echo '  s += ext(i + 37) * 39 + ext(s ^ 37);'
  echo '  s += ext(i + 38) * 40 + ext(s ^ 38);'
  echo '  s += ext(i + 39) * 41 + ext(s ^ 39);'
  echo '  s += ext(i + 40) * 42 + ext(s ^ 40);'
  echo '  s += ext(i + 41) * 43 + ext(s ^ 41);'
  echo '  s += ext(i + 42) * 44 + ext(s ^ 42);'
  echo '  s += ext(i + 43) * 45 + ext(s ^ 43);'
  echo '  s += ext(i + 44) * 46 + ext(s ^ 44);'
  echo '  s += ext(i + 45) * 47 + ext(s ^ 45);'
  echo '  s += ext(i + 46) * 48 + ext(s ^ 46);'
  echo '  s += ext(i + 47) * 49 + ext(s ^ 47);'
  echo '  s += ext(i + 48) * 50 + ext(s ^ 48);'
  echo '  s += ext(i + 49) * 51 + ext(s ^ 49);'
  echo '  s += ext(i + 50) * 52 + ext(s ^ 50);'
  echo '  s += ext(i + 51) * 53 + ext(s ^ 51);'
  echo '  s += ext(i + 52) * 54 + ext(s ^ 52);'
  echo '  s += ext(i + 53) * 55 + ext(s ^ 53);'
  echo '  s += ext(i + 54) * 56 + ext(s ^ 54);'
  echo '  s += ext(i + 55) * 57 + ext(s ^ 55);'
  echo '  s += ext(i + 56) * 58 + ext(s ^ 56);'
  echo '  s += ext(i + 57) * 59 + ext(s ^ 57);'
  echo '  s += ext(i + 58) * 60 + ext(s ^ 58);'
  echo '  s += ext(i + 59) * 61 + ext(s ^ 59);'
  echo '  return s;'
  echo '}'
  echo 'int f(int x) { return big(x) + big(x + 1) + big2(x) + big2(x + 1); }'
} > "$tmp/ai.c"
check "an always_inline callee over the size cap builds" pb -c "$tmp/ai.c" -o "$tmp/ai.o"
nm "$tmp/ai.o" | grep -q ' t big$' && bad "an always_inline function is inlined whatever its size" "an out-of-line copy of big remains" || ok "an always_inline function is inlined whatever its size"
nm "$tmp/ai.o" | grep -q ' t big2$' && ok "the same function without always_inline stays out of line (the cap still holds)" || bad "the same function without always_inline stays out of line" "$(nm "$tmp/ai.o" | tr '\n' ' ')"

# __attribute__((section("S"))) on a function puts it in S (the kernel's __init: .init.text), and such a function is not inlined
# into code outside the section.
cat > "$tmp/fs.c" <<'EOF2'
extern int ext(int);
static int __attribute__((section(".init.text"))) in_init(int x) { return ext(x) + 1; }
int __attribute__((section(".noinstr.text"))) other(int x) { return x * 3; }
int caller(int x) { return in_init(x) + other(x); }
EOF2
check "functions with a section attribute build" pb -c "$tmp/fs.c" -o "$tmp/fs.o"
readelf -SW "$tmp/fs.o" | grep -q ' \.init\.text ' && readelf -SW "$tmp/fs.o" | grep -q ' \.noinstr\.text ' && ok "the section attribute puts a function in its section" || bad "the section attribute puts a function in its section" "$(readelf -SW "$tmp/fs.o" | grep -c text) text sections"
nm "$tmp/fs.o" | grep -q ' t in_init$' && ok "a function with a section attribute is not inlined out of its section" || bad "a function with a section attribute is not inlined" "$(nm "$tmp/fs.o" | tr '\n' ' ')"

# -fno-PIE: the address of an external function is the symbol itself, not a data cell (a cell in .data that points into .init.text
# is a section mismatch for the kernel's modpost). With -fPIC (or with neither option) the cell stays.
printf 'extern void ext(void);\nvoid (*get(void))(void) { return ext; }\n' > "$tmp/fa.c"
pb -c -fno-PIE "$tmp/fa.c" -o "$tmp/fa1.o" && pb -c "$tmp/fa.c" -o "$tmp/fa2.o" && pb -c -fno-PIE -fPIC "$tmp/fa.c" -o "$tmp/fa3.o" &&
  ! nm "$tmp/fa1.o" | grep -q pathb_got && nm "$tmp/fa2.o" | grep -q pathb_got && nm "$tmp/fa3.o" | grep -q pathb_got &&
  ok "-fno-PIE: no cell for a function address (default and -fPIC keep it)" || bad "-fno-PIE: no cell for a function address" "$(nm "$tmp/fa1.o" "$tmp/fa2.o" "$tmp/fa3.o" | grep got | tr '\n' ' ')"

# C inline semantics: an inline function that an `extern` declaration (or a declaration without `inline`) completes is an external
# definition (one strong symbol, as gcc's: the kernel's `inline int task_curr(...)`, `STATIC inline int INIT unlzma(...)`); an inline
# definition no such declaration completes is no definition (the symbol is another unit's).
cat > "$tmp/ci.c" <<'EOF2'
extern int ext_def(int);
inline int ext_def(int x) { return x + 1; }
int plain_decl(int);
inline int plain_decl(int x) { return x + 2; }
inline int only_inline(int x) { return x + 3; }
int use(int x) { return ext_def(x) + plain_decl(x) + only_inline(x); }
EOF2
check "C inline definitions build" pb -c -ffreestanding "$tmp/ci.c" -o "$tmp/ci.o"
nm "$tmp/ci.o" | grep -q ' T ext_def$' && nm "$tmp/ci.o" | grep -q ' T plain_decl$' && ok "an inline function with an extern (or plain) declaration is an external definition" || bad "an inline function with an extern declaration is external" "$(nm "$tmp/ci.o" | tr '\n' ' ')"
nm "$tmp/ci.o" | grep -q ' U only_inline$' && ok "an inline definition without an extern declaration is not emitted (as gcc)" || bad "an inline definition without an extern declaration is not emitted" "$(nm "$tmp/ci.o" | tr '\n' ' ')"

# Dead code after inlining: a static function only a dead branch reached is not emitted (gcc's copy does not exist either), so its
# calls are not undefined references; a noinline function with an empty body is inlined (gcc's IPA drops its unused arguments).
cat > "$tmp/dc.c" <<'EOF2'
extern int ext(void);
extern int tab[], tab_end[];
static __attribute__((noinline)) int wp(int a) { return ext() + a; }
static inline int off(void) { return 0; }
static __attribute__((noinline)) void apply(int *s, int *e) { }
int f(int x) { apply(tab, tab_end); if (off()) return wp(x); return 7; }
EOF2
check "dead branches after inlining build" pb -c -ffreestanding "$tmp/dc.c" -o "$tmp/dc.o"
nm "$tmp/dc.o" | grep -qE ' U (ext|tab|tab_end)$| t (wp|apply)$' && bad "no copy of a function only a dead branch reached, no reference to an empty stub's arguments" "$(nm "$tmp/dc.o" | tr '\n' ' ')" || ok "no copy of a function only a dead branch reached, no reference to an empty stub's arguments"

# Inlining reaches what gcc's constant propagation does: a helper with a bool parameter, and a static function with one call site (gcc's
# -finline-functions-called-once, whatever its size), carry their constants into the body, where the branches they decide are folded and
# the calls in the dead ones are gone (no undefined reference to a function the configuration does not build).
cat > "$tmp/bp.c" <<'EOF2'
extern int never_defined(int);
static inline _Bool allowable(int a, _Bool smaps, _Bool in_pf) { return 0; }
static inline int create(int x) { return never_defined(x); }
int f(int x) { if (allowable(x, 0, 1)) return create(x); return 7; }
EOF2
check "a bool-parameter helper builds" pb -c -ffreestanding "$tmp/bp.c" -o "$tmp/bp.o"
nm "$tmp/bp.o" | grep -q ' U never_defined$' && bad "a bool-parameter helper is inlined, its dead branch is gone" "U never_defined" || ok "a bool-parameter helper is inlined, its dead branch is gone"
{
  echo 'extern int ext(int);'
  echo 'extern int never_defined(int);'
  echo 'static int big(int x, _Bool k) {'
  echo '  int s = 0;'
  echo '  s += ext(x + 0) * 2 + ext(s ^ 0);'
  echo '  s += ext(x + 1) * 3 + ext(s ^ 1);'
  echo '  s += ext(x + 2) * 4 + ext(s ^ 2);'
  echo '  s += ext(x + 3) * 5 + ext(s ^ 3);'
  echo '  s += ext(x + 4) * 6 + ext(s ^ 4);'
  echo '  s += ext(x + 5) * 7 + ext(s ^ 5);'
  echo '  s += ext(x + 6) * 8 + ext(s ^ 6);'
  echo '  s += ext(x + 7) * 9 + ext(s ^ 7);'
  echo '  s += ext(x + 8) * 10 + ext(s ^ 8);'
  echo '  s += ext(x + 9) * 11 + ext(s ^ 9);'
  echo '  s += ext(x + 10) * 12 + ext(s ^ 10);'
  echo '  s += ext(x + 11) * 13 + ext(s ^ 11);'
  echo '  s += ext(x + 12) * 14 + ext(s ^ 12);'
  echo '  s += ext(x + 13) * 15 + ext(s ^ 13);'
  echo '  s += ext(x + 14) * 16 + ext(s ^ 14);'
  echo '  s += ext(x + 15) * 17 + ext(s ^ 15);'
  echo '  s += ext(x + 16) * 18 + ext(s ^ 16);'
  echo '  s += ext(x + 17) * 19 + ext(s ^ 17);'
  echo '  s += ext(x + 18) * 20 + ext(s ^ 18);'
  echo '  s += ext(x + 19) * 21 + ext(s ^ 19);'
  echo '  s += ext(x + 20) * 22 + ext(s ^ 20);'
  echo '  s += ext(x + 21) * 23 + ext(s ^ 21);'
  echo '  s += ext(x + 22) * 24 + ext(s ^ 22);'
  echo '  s += ext(x + 23) * 25 + ext(s ^ 23);'
  echo '  s += ext(x + 24) * 26 + ext(s ^ 24);'
  echo '  s += ext(x + 25) * 27 + ext(s ^ 25);'
  echo '  s += ext(x + 26) * 28 + ext(s ^ 26);'
  echo '  s += ext(x + 27) * 29 + ext(s ^ 27);'
  echo '  s += ext(x + 28) * 30 + ext(s ^ 28);'
  echo '  s += ext(x + 29) * 31 + ext(s ^ 29);'
  echo '  s += ext(x + 30) * 32 + ext(s ^ 30);'
  echo '  s += ext(x + 31) * 33 + ext(s ^ 31);'
  echo '  s += ext(x + 32) * 34 + ext(s ^ 32);'
  echo '  s += ext(x + 33) * 35 + ext(s ^ 33);'
  echo '  s += ext(x + 34) * 36 + ext(s ^ 34);'
  echo '  s += ext(x + 35) * 37 + ext(s ^ 35);'
  echo '  s += ext(x + 36) * 38 + ext(s ^ 36);'
  echo '  s += ext(x + 37) * 39 + ext(s ^ 37);'
  echo '  s += ext(x + 38) * 40 + ext(s ^ 38);'
  echo '  s += ext(x + 39) * 41 + ext(s ^ 39);'
  echo '  s += ext(x + 40) * 42 + ext(s ^ 40);'
  echo '  s += ext(x + 41) * 43 + ext(s ^ 41);'
  echo '  s += ext(x + 42) * 44 + ext(s ^ 42);'
  echo '  s += ext(x + 43) * 45 + ext(s ^ 43);'
  echo '  s += ext(x + 44) * 46 + ext(s ^ 44);'
  echo '  s += ext(x + 45) * 47 + ext(s ^ 45);'
  echo '  s += ext(x + 46) * 48 + ext(s ^ 46);'
  echo '  s += ext(x + 47) * 49 + ext(s ^ 47);'
  echo '  s += ext(x + 48) * 50 + ext(s ^ 48);'
  echo '  s += ext(x + 49) * 51 + ext(s ^ 49);'
  echo '  s += ext(x + 50) * 52 + ext(s ^ 50);'
  echo '  s += ext(x + 51) * 53 + ext(s ^ 51);'
  echo '  s += ext(x + 52) * 54 + ext(s ^ 52);'
  echo '  s += ext(x + 53) * 55 + ext(s ^ 53);'
  echo '  s += ext(x + 54) * 56 + ext(s ^ 54);'
  echo '  s += ext(x + 55) * 57 + ext(s ^ 55);'
  echo '  s += ext(x + 56) * 58 + ext(s ^ 56);'
  echo '  s += ext(x + 57) * 59 + ext(s ^ 57);'
  echo '  s += ext(x + 58) * 60 + ext(s ^ 58);'
  echo '  s += ext(x + 59) * 61 + ext(s ^ 59);'
  echo '  if (k) s += never_defined(1234);'
  echo '  return s;'
  echo '}'
  echo 'int f(int x) { return big(x, 0); }'
} > "$tmp/once.c"
check "a big static function with one call site builds" pb -c -ffreestanding "$tmp/once.c" -o "$tmp/once.o"
nm "$tmp/once.o" | grep -qE ' U never_defined$| t big$' && bad "a static function with one call site is inlined whatever its size" "$(nm "$tmp/once.o" | tr '\n' ' ')" || ok "a static function with one call site is inlined whatever its size"

# -fPIE with -mno-sse (the kernel's boot decompressor, which allows no run-time relocations): gcc's compile; -fPIE alone stays Path B's
printf 'int f(int a, int b) { return a + b; }\n' > "$tmp/pie.c"
check "-fPIE -mno-sse compiles" pb -c -fPIE -mno-sse "$tmp/pie.c" -o "$tmp/pie1.o"
used gcc pie.c && ok "-fPIE with -mno-sse is gcc's compile" || bad "-fPIE with -mno-sse is gcc's compile" "$(tail -1 "$tmp/log")"
check "-fPIE compiles" pb -c -fPIE "$tmp/pie.c" -o "$tmp/pie2.o"
used pathb pie.c && ok "-fPIE alone is Path B's compile" || bad "-fPIE alone is Path B's compile" "$(tail -1 "$tmp/log")"

# The kernel's .head.text runs identity-mapped before its page tables: a unit with a function in it takes the addresses of globals as the
# link-time absolute ones (R_X86_64_32S, gcc's kernel model; qbe -A), any other unit rip-relative ones
cat > "$tmp/hd.c" <<'EOF2'
extern char _text[];
unsigned long __attribute__((section(".head.text"))) hd(unsigned long phys) { return phys - ((unsigned long)_text - 0xffffffff80000000UL); }
EOF2
printf 'extern char _text[];\nunsigned long other(unsigned long phys) { return phys - ((unsigned long)_text - 0xffffffff80000000UL); }\n' > "$tmp/nohd.c"
check ".head.text unit builds" pb -c "$tmp/hd.c" -o "$tmp/hd.o"
check "a unit without .head.text builds" pb -c "$tmp/nohd.c" -o "$tmp/nohd.o"
objdump -dr "$tmp/hd.o" | grep -q 'R_X86_64_32S.*_text' && ok ".head.text: global addresses are absolute" || bad ".head.text: global addresses are absolute" "$(objdump -dr "$tmp/hd.o" | grep _text | head -2 | tr '\n' ' ')"
objdump -dr "$tmp/nohd.o" | grep -q 'R_X86_64_PC32.*_text' && ok "other units: global addresses are rip-relative" || bad "other units: global addresses are rip-relative" "$(objdump -dr "$tmp/nohd.o" | grep _text | head -2 | tr '\n' ' ')"

# An asm memory operand on a global object is the object itself, `sym(%rip)` (the kernel's `lgdt %0` of head64.c's startup_gdt_descr, run
# identity-mapped before the page tables that map the object's link-time address); one on a pointer's target stays an address
cat > "$tmp/mo.c" <<'EOF2'
struct dp { unsigned short size; unsigned long address; } __attribute__((packed));
static struct dp gdt_descr = { 10, 0 };
void setup(unsigned long a) { gdt_descr.address = a; asm volatile("lgdt %0" :: "m"(gdt_descr)); }
void viaptr(const struct dp *p) { asm volatile("lgdt %0" :: "m"(*p)); }
EOF2
check "asm memory operands build" pb -c "$tmp/mo.c" -o "$tmp/mo.o"
[ "$(objdump -d "$tmp/mo.o" | grep -c 'lgdt   0x0(%rip)')" = 1 ] && [ "$(objdump -d "$tmp/mo.o" | grep -c 'lgdt   (%rax)')" = 1 ] &&
  ok "a memory operand on a global is sym(%rip), on a pointer's target (%reg)" || bad "asm memory operand forms" "$(objdump -d "$tmp/mo.o" | grep lgdt | tr '\n' ' ')"
# the helper that names a symbol is in the section of its caller (modpost: no reference from .text to an __init object)
printf 'static int initdata;\nvoid __attribute__((section(".init.text"))) f(void) { asm volatile("lgdt %%0" :: "m"(initdata)); }\nvoid g(void) { asm volatile("lgdt %%0" :: "m"(initdata)); }\n' > "$tmp/ms.c"
check "asm helpers in sections build" pb -c "$tmp/ms.c" -o "$tmp/ms.o"
objdump -t "$tmp/ms.o" | grep __pathb_asm | awk '{print $4}' | sort | tr '\n' ' ' | grep -q '^.init.text .text $' && ok "an asm helper that names a symbol is in its caller's section" || bad "an asm helper that names a symbol is in its caller's section" "$(objdump -t "$tmp/ms.o" | grep __pathb_asm | awk '{print $4}' | tr '\n' ' ')"

# A static local with __attribute__((used)) is emitted where it is declared (the kernel's __ADDRESSABLE in static_call(): its job is to
# make the object reference the key, so that the object's symbol table has it, which objtool looks up)
cat > "$tmp/ad.c" <<'EOF2'
struct key { int x; };
extern struct key __SCK__apic_call_write;
extern void tramp(int);
static inline void apic_write(int v) {
  ({ static void *__attribute__((used, section(".discard.addressable"))) __addr = (void *)&__SCK__apic_call_write; });
  tramp(v);
}
void f(void) { apic_write(1); }
EOF2
check "a static local with the used attribute builds" pb -c "$tmp/ad.c" -o "$tmp/ad.o"
nm "$tmp/ad.o" | grep -q ' U __SCK__apic_call_write$' && ok "the used static local is emitted: the object references the key" || bad "the used static local is emitted" "$(nm "$tmp/ad.o" | tr '\n' ' ')"

# A function attribute `alias` to a static function defined later: the target is kept (the kernel's SYSCALL_DEFINE0 stubs), and
# __builtin_isdigit is inline (the kernel's isdigit), not a call of the libc function.
cat > "$tmp/al.c" <<'EOF2'
static long __do_sys_getpid(void);
long __x64_sys_getpid(const void *regs) __attribute__((alias("__do_sys_getpid")));
static long __do_sys_getpid(void) { return 42; }
int dig(int c) { return __builtin_isdigit(c); }
EOF2
check "an alias of a static function, and __builtin_isdigit, build" pb -c -ffreestanding "$tmp/al.c" -o "$tmp/al.o"
nm "$tmp/al.o" | grep -q ' T __x64_sys_getpid$' && nm "$tmp/al.o" | grep -q ' t __do_sys_getpid$' && ok "the static target of an alias is emitted with it" || bad "the static target of an alias is emitted" "$(nm "$tmp/al.o" | tr '\n' ' ')"
nm "$tmp/al.o" | grep -q ' U isdigit$' && bad "__builtin_isdigit is not a call of isdigit" "U isdigit" || ok "__builtin_isdigit is inline"
printf 'int isd(int);\nint main(void) { return isd(55) * 10 + isd(47) + isd(-1) * 100; }\n' > "$tmp/isd.c"
printf 'int isd(int c) { return __builtin_isdigit(c); }\n' > "$tmp/isd2.c"
check "__builtin_isdigit gives 1 for a digit and 0 for others" pb "$tmp/isd.c" "$tmp/isd2.c" -o "$tmp/isd"
"$tmp/isd"; [ $? = 10 ] && ok "__builtin_isdigit values" || bad "__builtin_isdigit values" "exit $?"

# A function with a section attribute is inlined into a caller of the same section, not into another
cat > "$tmp/ss.c" <<'EOF2'
extern int ext(int);
static int __attribute__((section(".head.text"))) chk(int x) { return x ? 0 : 1; }
int __attribute__((section(".head.text"))) in_head(int x) { return chk(x) + ext(x); }
int outside(int x) { return chk(x); }
EOF2
check "functions of one section call each other" pb -c "$tmp/ss.c" -o "$tmp/ss.o"
ncalls() { objdump -dr "$tmp/ss.o" | awk -v fn="<$1>:" '$2 == fn {f=1; next} /^$/ {f=0} f' | grep -cE 'call|jmp  '; }
[ "$(ncalls in_head)" = 1 ] && ok "a callee of the caller's own section is inlined (one call left: ext)" || bad "a callee of the caller's own section is inlined" "in_head has $(ncalls in_head) calls"
[ "$(ncalls outside)" = 1 ] && ok "a callee of another section is not inlined" || bad "a callee of another section is not inlined" "outside has $(ncalls outside) calls"

# The default stays qbe
if [ -x "$root/build/cproc/cproc-qbe" ]; then
  out=$("$nfcc" --version); grep -q 'backend qbe' <<<"$out" && ok "default backend is qbe" || bad "default backend is qbe" "$out"
fi
echo "nfcc pathb: $pass passed, $fail failed"
[ $fail = 0 ]
