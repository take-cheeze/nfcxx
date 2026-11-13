#!/usr/bin/env bash
# nfcc with NFCXX_BACKEND=pathb: EDG's C front end -> typed IR -> QBE (docs/notes/nfcc-pathb.md). Needs the Path B harness
# (scripts/setup-edg.sh, setup-qbe.sh, setup-pathb.sh). The default backend is Path B where its harness is built (checked below).
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
# -Wa,*: options of the assembler step. Path B assembles QBE's output with the host cc, so the ones that mean the same for it are
# passed on to that step (scripts/pathb-cc --as-opt) and the compile stays Path B's; any other is gcc's.
printf 'extern int ext;\nint rd(void) { return ext; }\n' > "$tmp/rl.c"
check "-Wa,--fatal-warnings --noexecstack builds" pb -c -Wa,--fatal-warnings -Wa,--noexecstack -I"$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/wa.o"
used pathb a.c && ok "-Wa,--fatal-warnings stays on Path B" || bad "-Wa,--fatal-warnings stays on Path B" "$(tail -1 "$tmp/log")"
check "-Wa,-mrelax-relocations=no builds" pb -c -fPIC -Wa,-mrelax-relocations=no "$tmp/rl.c" -o "$tmp/rl_no.o"
used pathb rl.c && ok "-Wa,-mrelax-relocations=no stays on Path B" || bad "-Wa,-mrelax-relocations=no stays on Path B" "$(tail -1 "$tmp/log")"
check "no -Wa: the default relocation" pb -c -fPIC "$tmp/rl.c" -o "$tmp/rl_def.o"
objdump -r "$tmp/rl_no.o" | grep -q 'R_X86_64_GOTPCREL ' && ok "-Wa,-mrelax-relocations=no reached the assembler (R_X86_64_GOTPCREL)" || bad "-Wa,-mrelax-relocations=no reached the assembler" "$(objdump -r "$tmp/rl_no.o" | grep GOT)"
objdump -r "$tmp/rl_def.o" | grep -q 'R_X86_64_REX_GOTPCRELX' && ok "default: relaxable relocation (R_X86_64_REX_GOTPCRELX)" || bad "default: relaxable relocation" "$(objdump -r "$tmp/rl_def.o" | grep GOT)"
check "-Wa,a,b (comma list) builds" pb -c -Wa,--fatal-warnings,-mrelax-relocations=no "$tmp/rl.c" -o "$tmp/rl_l.o"
used pathb rl.c && ok "a comma list of known -Wa options stays on Path B" || bad "a comma list of known -Wa options" "$(tail -1 "$tmp/log")"
check "-Wa,--defsym compiles with gcc" pb -c -Wa,--defsym,WA_SYM=1 -I"$tmp/inc" -DEXTRA=1 "$tmp/a.c" -o "$tmp/wa2.o"
used gcc a.c && ok "an unknown -Wa option went to gcc" || bad "an unknown -Wa option went to gcc" "$(tail -1 "$tmp/log")"
tail -1 "$tmp/log" | grep -q 'assembler option' && ok "the log says why" || bad "the log says why" "$(tail -1 "$tmp/log")"
nm "$tmp/wa2.o" | grep -q WA_SYM && ok "-Wa,--defsym reached gcc's assembler" || bad "-Wa,--defsym reached gcc's assembler" "$(nm "$tmp/wa2.o")"
# the kernel's options that change the code and that QBE cannot write: gcc's, never dropped (-mindirect-branch=thunk*: retpolines;
# -mindirect-branch-register, -mindirect-branch-cs-prefix, -mrecord-mcount, -fpatchable-function-entry, -fzero-call-used-regs, ...)
for o in -mindirect-branch=thunk-extern -mfunction-return=thunk-extern -mharden-sls=all -mindirect-branch-register -mindirect-branch-cs-prefix \
         -mrecord-mcount -fpatchable-function-entry=16,16 -fzero-call-used-regs=used-gpr -frandomize-layout-seed-file=/nonexistent-seed \
         -ftrivial-auto-var-init=pattern -m32; do
  pb -c $o "$tmp/int.c" -o "$tmp/o.o" >/dev/null 2>&1; used gcc int.c && tail -1 "$tmp/log" | grep -qF -- "$o" && ok "$o is gcc's" || bad "$o is gcc's" "$(tail -1 "$tmp/log")"
done
# the same options asking for nothing are dropped: Path B builds
check "=keep / =none options" pb -c -mindirect-branch=keep -mfunction-return=keep -mharden-sls=none "$tmp/int.c" -o "$tmp/o.o"
used pathb int.c && ok "-mindirect-branch=keep -mfunction-return=keep -mharden-sls=none: Path B" || bad "keep/none: Path B" "$(tail -1 "$tmp/log")"
# -mstack-protector-guard*: only meaningful with a stack protector in effect (the last -fstack-protector* / -fno-stack-protector)
sg="-mstack-protector-guard=global -mstack-protector-guard-reg=fs -mstack-protector-guard-symbol=__stack_chk_guard"
check "stack-protector guard options, no protector" pb -c $sg "$tmp/int.c" -o "$tmp/o.o"
used pathb int.c && ok "guard options without -fstack-protector: Path B" || bad "guard options without -fstack-protector" "$(tail -1 "$tmp/log")"
check "guard options, -fno-stack-protector last" pb -c -fstack-protector-strong $sg -fno-stack-protector "$tmp/int.c" -o "$tmp/o.o"
used pathb int.c && ok "guard options, -fno-stack-protector last: Path B" || bad "guard options, -fno-stack-protector last" "$(tail -1 "$tmp/log")"
check "guard options with -fstack-protector-strong" pb -c $sg -fstack-protector-strong "$tmp/int.c" -o "$tmp/o.o"
used gcc int.c && tail -1 "$tmp/log" | grep -q 'stack-protector-guard' && ok "guard options with a protector (given before it): gcc" || bad "guard options with a protector: gcc" "$(tail -1 "$tmp/log")"
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

# The default backend: Path B on x86-64 Linux when the harness is built (a unit it cannot take goes to gcc), qbe otherwise; NFCXX_BACKEND chooses.
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  out=$(env -u NFCXX_BACKEND -u NFCXX_PATHB_FALLBACK "$nfcc" --version)
  grep -q 'backend pathb' <<<"$out" && ok "default backend is pathb (harness built)" || bad "default backend is pathb (harness built)" "$out"
  printf 'int plain(int x) { return x * 3 + 1; }\n' > "$tmp/plain.c"
  rm -f "$tmp/dlog"
  if env -u NFCXX_BACKEND -u NFCXX_PATHB_FALLBACK NFCXX_PATHB_LOG="$tmp/dlog" "$nfcc" -c "$tmp/plain.c" -o "$tmp/d1.o" >/dev/null 2>&1 &&
     grep -q '^pathb ' "$tmp/dlog"; then ok "default: a plain unit is made by Path B"; else bad "default: a plain unit is made by Path B" "$(cat "$tmp/dlog" 2>&1)"; fi
  rm -f "$tmp/dlog"
  if env -u NFCXX_BACKEND -u NFCXX_PATHB_FALLBACK NFCXX_PATHB_LOG="$tmp/dlog" "$nfcc" -c -fshort-enums "$tmp/plain.c" -o "$tmp/d2.o" >/dev/null 2>&1 &&
     grep -q '^gcc ' "$tmp/dlog"; then ok "default: a unit with an option Path B cannot honour is made by gcc"; else bad "default: a unit with an option Path B cannot honour is made by gcc" "$(cat "$tmp/dlog" 2>&1)"; fi
  # a unit Path B itself refuses (inline asm it cannot emit) falls back to gcc by default, but not with an explicit NFCXX_BACKEND=pathb
  cat > "$tmp/refuse.c" <<'EOF2'
int f(int x) { int r; __asm__ volatile("lea 1(%1), %0" : "=r"(r) : "r"(x), "i"(sizeof(int)) : "cc", "memory"); return r; }
EOF2
  if NFCXX_BACKEND=pathb "$nfcc" -c "$tmp/refuse.c" -o "$tmp/d3.o" >/dev/null 2>&1; then :; else
    env -u NFCXX_BACKEND -u NFCXX_PATHB_FALLBACK "$nfcc" -c "$tmp/refuse.c" -o "$tmp/d3.o" >/dev/null 2>&1 &&
      ok "default: a unit Path B refuses is made by gcc" || bad "default: a unit Path B refuses is made by gcc" ""
  fi
fi
out=$(NFCXX_BACKEND=qbe "$nfcc" --version 2>&1) && grep -q 'backend qbe' <<<"$out" && ok "NFCXX_BACKEND=qbe still chooses qbe" || { [ -x "$root/build/cproc/cproc-qbe" ] && bad "NFCXX_BACKEND=qbe still chooses qbe" "$out"; }
echo "nfcc pathb: $pass passed, $fail failed"
[ $fail = 0 ]
