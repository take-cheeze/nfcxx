# nfcc on Path B (`NFCXX_BACKEND=pathb`)

`nfcc`, the `cc` drop-in for make, CMake, autoconf and the Linux kernel build, has three backends: `qbe` (the default:
cproc -> QBE), `cil` and `gcc`. `NFCXX_BACKEND=pathb` adds a fourth, **opt-in** one: each C source goes through
`scripts/pathb-cc` in C mode (EDG's C front end -> typed IR -> QBE IL, no cproc), the route `./nfcxx` takes for a C input.
The default stays `qbe`.

```
NFCXX_BACKEND=pathb nfcc -c a.c -o a.o        compile (-O*, -g*, -W*, -fPIC ... are accepted and do not change the object)
NFCXX_BACKEND=pathb nfcc a.o b.c -lm -o prog   link: the host cc, with EDG's runtime (libC.a), the long double helpers, libatomic
NFCXX_BACKEND=pathb nfcc -S a.c -o a.s         the assembly Path B hands to the assembler
```

`-E`, `-M`, `-MM`, `-fsyntax-only` and the queries go to the host compiler as for every backend; `-MD`/`-MMD -MF -MT -MQ -MP`
with `-c` write the dependency file with the host preprocessor, as today. nfcc's flag handling is shared; what differs
is what reaches Path B.

## What Path B honours, and what it refuses

`scripts/pathb-cc` understands `-I`, `-D`, `-U`, `-include` and a C standard (`-std=c89..c23`; `-std=gnuNN` and `-ansi`
are mapped to the matching `-std=cNN`, EDG's gcc mode takes the GNU extensions in every standard). It ignores any other
option. nfcc therefore stops, with a message naming the option and a non-zero status (1, `nfcc: error: ...`), on what Path B
cannot honour instead of dropping it:

| option | result |
|---|---|
| `-isystem`, `-iquote`, `-idirafter`, `-imacros`, `-nostdinc`, `-undef`, `--sysroot=` | refused (`not supported by the pathb backend`) |
| `-Wa,*` | refused (Path B assembles with the host cc) |
| `-funsigned-char`, `-fshort-wchar`, `-ffreestanding`, `-fsanitize*`, `-fopenmp`, `-ffast-math`, `-m32`, other semantic `-f`/`-m` options, C++ | refused as on the qbe backend (no `NFCXX_GCC_PASSTHROUGH`/`NFCXX_QBE_KERNEL` on this backend) |
| `-O*`, `-g*`, `-W*`, `-fPIC`, `-fwrapv`, `-fno-strict-aliasing`, `-m64`, `-mtune=`, `-march=` ... | accepted, no effect (as on qbe) |

A translation unit Path B itself refuses (an unsupported construct) exits with Path B's status, 3, and a
`pathb-cc: FILE: SSA route: ...` line, so a build system sees a failed compile. There is no fallback to another
backend in nfcc (`./nfcxx` falls back to gcc by default; nfcc, as a `cc`, does not choose for the build).

Test: `tests/nfcc/run.sh`.

## Measuring: `scripts/nfcc-pathb-measure.sh`

`scripts/nfcc-pathb-measure.sh [-o REPORT] FILE.c...` compiles each file with `nfcc -c` on `pathb` and prints the number
built and the refusals grouped by reason (the SSA route's line or the front end's error, with paths, quoted names and
numbers removed). The result is in docs/notes/linux-kernel.md.
