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
| `-iquote`, `-imacros`, `-undef`, `--sysroot=`, `-Wa,*` other than `--fatal-warnings`, `--noexecstack`, `-W`, `--no-warn`, `-mrelax-relocations=`, `-mx86-used-note=` (those go to the assembler step), `-m16`/`-m32`/`-mx32`, `-fshort-enums`, `-fpack-struct`, `-ftrivial-auto-var-init=`, `-ffast-math`, other semantic `-f`/`-m` options, an `-f` option nfcc does not know | the compile goes to **gcc**; an unknown option is then gcc's own error |
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

Test: `tests/nfcc/run.sh`.

## Measuring: `scripts/nfcc-pathb-measure.sh`

`scripts/nfcc-pathb-measure.sh [-o REPORT] FILE.c...` compiles each file with `nfcc -c` on `pathb` and prints the number
built and the refusals grouped by reason (the SSA route's line or the front end's error, with paths, quoted names and
numbers removed). The result is in docs/notes/linux-kernel.md.
