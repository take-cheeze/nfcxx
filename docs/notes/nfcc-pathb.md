# nfcc on Path B (`NFCXX_BACKEND=pathb`)

`nfcc`, the `cc` drop-in for make, CMake, autoconf and the Linux kernel build, has three backends: `qbe` (the default:
cproc -> QBE), `cil` and `gcc`. `NFCXX_BACKEND=pathb` adds a fourth, **opt-in** one: each C source goes through
`scripts/pathb-cc` in C mode (EDG's C front end -> typed IR -> QBE IL, no cproc), the route `./nfcxx` takes for a C input.
The default stays `qbe`.

```
NFCXX_BACKEND=pathb nfcc -c a.c -o a.o        compile (-O*, -g*, -W*, ... are accepted and do not change the object; -fPIC and -shared make the object fit a shared object, see below)
NFCXX_BACKEND=pathb nfcc a.o b.c -lm -o prog   link: the host cc, with EDG's runtime (libC.a), the long double helpers, libatomic
NFCXX_BACKEND=pathb nfcc -S a.c -o a.s         the assembly Path B hands to the assembler
```

`-E`, `-M`, `-MM`, `-fsyntax-only` and the queries go to the host compiler as for every backend; `-MD`/`-MMD -MF -MT -MQ -MP`
with `-c` write the dependency file with the host preprocessor, as today. nfcc's flag handling is shared; what differs
is what reaches Path B.

## What Path B honours, and what it refuses

`scripts/pathb-cc` understands `-I`, `-D`, `-U`, `-include` and a C standard (`-std=c89..c23`; `-std=gnuNN` and `-ansi`
are mapped to the matching `-std=cNN`, EDG's gcc mode takes the GNU extensions in every standard), and the options of
the Linux kernel's command line below. It ignores any other option, so nfcc sorts every option into one of three
classes and never drops one that changes what the program means:

1. **honoured by Path B**: the table's first rows;
2. **no effect on QBE's code**: dropped, as on the qbe backend;
3. **changes meaning, and Path B has no equivalent**: the compile is made by **gcc**, with the options as given
   (every `-f` and `-m` option in command-line order, `-O`, `-g`, `-I`/`-D`, `-Wa,*`). It is neither dropped nor an error.
   `NFCXX_PATHB_LOG=FILE` appends `pathb SRC` or `gcc SRC: reason` per compile.

| option | result |
|---|---|
| `-nostdinc` | honoured: the host's system include directories are not searched (`pathb-dump`: no `host_sys_includes`); EDG's own `include` directory, which holds C++ headers only, stays |
| `-isystem DIR`, `-isystemDIR`, `-idirafter DIR` | honoured: EDG's `--sys_include`, `-isystem` before the host's directories, `-idirafter` after them. gcc's `-nostdinc -isystem $(gcc -print-file-name=include)` gives `<stdarg.h>` and `<stddef.h>` |
| `-funsigned-char`, `-fno-signed-char`; `-fsigned-char`, `-fno-unsigned-char` | honoured: EDG's `--unsigned_chars` / `--signed_chars` (constants, comparisons, `CHAR_MIN`, `__CHAR_UNSIGNED__`), and the IR's `char` becomes `unsigned_char` (the emitters read `char` as signed) |
| `-fshort-wchar` | honoured for the headers: `__WCHAR_TYPE__`, `__WCHAR_MAX__`, `__WCHAR_MIN__`, `__WCHAR_WIDTH__`, `__SIZEOF_WCHAR_T__` are gcc's, so `wchar_t` is `unsigned short`. EDG has no option for the type of a wide literal (`L"x"` stays `int`): a unit whose preprocessed text has `L'` or `L"` is made by gcc |
| `-ffreestanding` | honoured: `__STDC_HOSTED__` is 0. The headers are still the ones on the include path: choose them with `-nostdinc -isystem` |
| `-mno-sse`, `-mno-sse2`, `-mno-80387`, `-msoft-float` | checked, as `qbe-cc` does: QBE runs with `-n` (no `%xmm15` for integer moves) and the assembly of the unit is refused (status 5, `uses SSE or x87`) when it names an SSE or x87 register or an x87 instruction. Inline asm is the program's own and is not checked. See `NFCXX_PATHB_FALLBACK` below |
| `-fno-asynchronous-unwind-tables` | honoured: QBE `-U`, no `.cfi` directives and so no `.eh_frame` |
| `-mno-red-zone`, `-mcmodel=`, `-mtune=`, `-mpreferred-stack-boundary=`, `-mno-mmx`, `-mno-avx`, `-fno-PIE`, `-fno-stack-protector`, `-fno-jump-tables`, `-fno-delete-null-pointer-checks`, `-fno-strict-overflow`, `-fno-common`, `-fcf-protection=`, `-fconserve-stack`, `-fstrict-flex-arrays=`, ... | no effect on QBE's code (it never uses the red zone, makes no jump tables or stack protector, assumes nothing from overflow or null checks, and writes PIC code that a non-PIE link takes): dropped on Path B, kept for a gcc compile |
| `-m16`, with `-march=i386 -mregparm=3 -mpreferred-stack-boundary=2` (the kernel's real-mode boot code) | honoured: the 32-bit x86 target, below. `-mregparm=3` without `-m16` is gcc's |
| `-iquote`, `-imacros`, `-undef`, `--sysroot=`, `-Wa,*`, `-m32`/`-mx32`, `-fshort-enums`, `-fpack-struct`, `-ftrivial-auto-var-init=`, `-ffast-math`, other semantic `-f`/`-m` options, an `-f` option nfcc does not know | the compile goes to **gcc**; an unknown option is then gcc's own error |
| `-fsanitize*`, `-fopenmp`, `-fprofile*`, `--coverage`, `-fstack-check`, C++ | refused (instrumentation would be dropped), as on the other backends |
| `-O*`, `-g*`, `-W*`, `-fwrapv`, `-fno-strict-aliasing`, `-m64`, `-march=` ... | accepted, no effect (as on qbe) |
| `-fPIC`, `-fpic`, `-shared` | honoured: `--pic` (below) |

`-fPIC`, `-fpic` and `-shared` pass `--pic` to `scripts/pathb-cc` (`nfcxx` does too for `-shared` and `-fPIC`): the object is meant for a
shared object, so the address of an exported function is read from a pointer cell and the address of an exported or extern data
object through the GOT, never as a PC-relative reference (`ld`: "relocation R_X86_64_PC32 ... can not be used when making a shared
object"). The gnu dialects (gcc's default, `-std=gnuNN`) also get `-D_DEFAULT_SOURCE`, which glibc implies for gcc but EDG's C mode
turns off with its `_POSIX_SOURCE`; a strict `-std=cNN` does not.

A translation unit Path B itself refuses (an unsupported construct, or SSE code under `-mno-sse`) exits with Path B's
status (3, 5, ...) and a `pathb-cc: FILE: SSA route: ...` line, so a build system sees a failed compile. With
`NFCXX_PATHB_FALLBACK=gcc` nfcc makes that compile with gcc instead (the log line is `gcc SRC: Path B refused it (status N)`),
which is how a kernel build keeps going on the files Path B cannot do (inline asm it cannot emit, the real-mode boot
code); without it nfcc, as a `cc`, does not choose for the build. The `-ftrivial-auto-var-init=zero` of a kernel with
`CONFIG_INIT_STACK_ALL_ZERO` sends every file to gcc: Path B does not zero automatic variables.

## The 32-bit x86 target: `-m16 -march=i386 -mregparm=3 -mpreferred-stack-boundary=2` (the kernel's real-mode boot code)

`scripts/pathb-cc --i386 [--regparm=3] [--m16]` (nfcc gives it for `-m16`, `-mregparm=3`, and drops `-march=i386` and
`-mpreferred-stack-boundary=2`, which change nothing on QBE's i386 code) compiles for 32-bit x86:

- the front end reads the unit as EDG's `linux_i686` and freestanding (the host's 64-bit headers are not read: the kernel gives
  `-nostdinc -isystem`): `long`, `unsigned long` and pointers are 4 bytes, `long long` 8 and aligned on 4 in a structure, `va_list`
  is `char *` (`NFCXX_IR_VALIST_PTR`, set by `pathb-dump` for `linux_i686`; the other targets keep the System V tag);
- `scripts/pathb-ssa-build --target=i386|i386_regparm3 [--m16]` emits the module for QBE's i386 targets (the fork's
  `3rd/qbe/doc/i386.txt`; no change to QBE is needed). The module's layout (`(pointer 4)`) selects `Qbe.ptr32`: pointers are of class `w`,
  and the IR's `long` and `unsigned_long` are read as `int` and `unsigned_int` (a hex literal is brought into its range as a 32-bit type),
  `long long` stays `l` (QBE does it as pairs of words, its divisions are calls of libgcc's `__divdi3`, ...). An aggregate's
  leaves are spelled with words (`l`, `d` on 4 is not a QBE layout). Structures, arguments, results, `-mregparm=3` and variadic
  functions follow QBE's i386 ABI, which is gcc's, so objects of gcc and of QBE call each other (`tests/pathb-i386`);
- `-m16` gives `.code16gcc`: the code is 32-bit code, and gas adds the operand and address size prefixes. The object is ELF32
  (`cc -m32 -c`), the code is 16-bit code by its bytes (`objdump -d -m i8086`);
- no checks: a bare target has no runtime to trap into and gcc makes none, so the null, shift and bounds checks of the IR are
  not emitted (the hardware's own #DE and the masking of a shift count are the behaviour); no jump tables (QBE's i386 has none);
- inline asm: each template is a helper (`Qbe.asm_block32`: the operand block at `%eax` with `-mregparm=3` or at `4(%esp)`, one
  4-byte cell an operand, `%ebp` the block while the template runs, `%ebx %esi %edi %ebp` saved, the registers `eax ecx edx ebx
  esi edi` and the byte registers for a 1-byte operand), the helper and its COMDAT section named after a hash of the template, so
  that a link keeps one copy. `%esp` in a template (`leal %P1(%%esp),%0`, `main.c`) is moved by the helper's frame; any other use of
  `%esp`, a template that names `%ebp`, an operand of 8 bytes, an SSE operand, and a memory operand that finds no register
  (the helper takes the address of a `"m"` operand in one) are refused. The empty template with a tied pointer and integer
  (`absolute_pointer()`), a `bool` output (`CC_OUT(nz)` as `setnz`) and the address of a symbol narrowed to 16 bits (`(u16)(size_t)&buf`,
  a mask: `movzwl $sym` is not an instruction) are handled as for the other targets or in the emitter;
- volatile accesses are calls of local helpers, only the ones the unit uses; `-mno-sse` is the default (QBE's i386 has no floating
  point: a unit with `float` or `double` is refused, status 3, or is gcc's with `NFCXX_PATHB_FALLBACK=gcc`), no long double, no
  thread-local objects, no atomics, no `--safe`/`--asan`;
- no inlining for `-m16` (`--ir-opt=none`): the image of the boot code is size limited and the inliner grows it by a third. The
  code is still about twice gcc's `-Os` size (QBE keeps a frame pointer, loads before it compares, and the asm thunks and volatile helpers
  are calls): the boot code of Linux 6.8 (tinyconfig, 21 files) is 26.5 KB of text with Path B and 13.7 KB with gcc, and the real-mode
  setup is limited to 32 KB (`SETUP_SECT_MAX`, with `header.S` and `copy.S` besides). A larger configuration may not fit.

Tests: `tests/pathb-i386/run.sh` (each case built by Path B and by gcc -m32, cdecl and regparm, linked with a gcc-built runtime and
run as a 32-bit Linux program; the real-mode build of each case is read back with objdump), `tests/pathb-i386/realmode.sh` (the real-mode
code in qemu-system-i386: a boot sector loads it, it writes to the debug console, the output must equal gcc `-m16`'s; the kernel's
own `string.c`, `printf.c` and `cpuflags.c` were run this way with `REALMODE_SRCS`, see docs/notes/linux-kernel.md) and the `-m16` checks of
`tests/nfcc/run.sh`.

Test: `tests/nfcc/run.sh`.

## Measuring: `scripts/nfcc-pathb-measure.sh`

`scripts/nfcc-pathb-measure.sh [-o REPORT] FILE.c...` compiles each file with `nfcc -c` on `pathb` and prints the number
built and the refusals grouped by reason (the SSA route's line or the front end's error, with paths, quoted names and
numbers removed). The result is in docs/notes/linux-kernel.md.
