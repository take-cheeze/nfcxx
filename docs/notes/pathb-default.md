# Path B as the default backend

On x86-64 Linux, `./nfcxx` now builds with Path B unless the request needs something only qbe or gcc does. This note
says what the default covers, what falls back, and how to get the old behaviour.

## Rules (nfcxx, the backend choice before the ASan checks)

Path B is chosen when all of these hold:

- no `--backend=` and no `NFCXX_BACKEND` (both are used as given);
- `--freestanding` takes Path B on x86-64 Linux only: the front end reads `lib/` and no host headers (`scripts/pathb-dump --freestanding`,
  GNU 13 emulation), the program links EDG's runtime and libc, not the host's libstdc++ (`docs/notes/freestanding.md`); on other hosts it keeps qbe;
- not `--cosmo` (cosmocc is a gcc-backend link);
- not `--emit-c`, `--target=`, `-E`, `-M` or `-shared`;
- the host is `Linux x86_64` (`scripts/pathb-cc` assembles x86-64 QBE output with `cc`).

Anything else gets qbe, as before (a fallback from Path B goes to gcc, below). `-fsanitize=address` is not an exclusion: since PR #892 Path B instruments the code itself
(`scripts/pathb-cc --asan`, `docs/notes/asan.md` "Path B"), and a program it does not build is rebuilt with the gcc backend, which has ASan too.
`-fsafe-pointers` still selects Path B, as it did (`-fsanitize=undefined` is meant to, `docs/notes/ubsan.md`).

Path B is asked for by name with `--backend=pathb` (the old spelling is `NFCXX_PATH=b`; both keep the hard errors, below), and the flags that
were environment variables for the scripts under it are `scripts/pathb-cc` options now (`--asan`, `--safe-pointers`, `--ir-opt=LIST`, `--emitter=`,
`--sanitize=`, `--keep=`) and `scripts/pathb-dump` options (`--ir-loc`, `--ir-scopes`, `--borrow`, `--sanitize=`, `--cuda-device`). Each variable still works as
the fallback; the flag wins.

## CUDA (.cu inputs)

A `.cu` input takes Path B by default too. Its host copy is rewritten (the `<<<...>>>` launches become calls, the copy
gets the forced `nfcxx_cuda.h` include and is read with the launch syntax, `--cuda`), and its device image is a
file-scope asm block (`pathb-ptx-emit --embed`), which Path B writes into the object as it is. `tests/cuda/libs/run.sh`
passes on the default driver and with `NFCXX_BACKEND=qbe`. `nfcc` (the C compiler for CMake) is C-only and keeps its own
backend choice.

## Fallback

A default-selected Path B build that fails on any `.cpp` file is rebuilt with the gcc backend. The driver prints one line naming
the file and the status, then runs itself again with `NFCXX_BACKEND=gcc`. gcc compiles EDG's C with C semantics
(`-fwrapv -fno-strict-aliasing`), so the message says so: a refused program does not get Path B's UB-freedom. Status 3 is a construct Path B refuses (the
reason is on stderr from `scripts/pathb-cc`); other statuses are Path B faults. If gcc fails too, its error is what is
shown. An explicit `--backend=pathb` (or `NFCXX_PATH=b`) keeps the hard errors.

## Why these exclusions

| Option | Under Path B | Default now |
|---|---|---|
| `--freestanding`, not x86-64 Linux | refused | qbe |
| `--cosmo` | would run Path B silently | qbe (gcc) |
| non-x86-64 host | `pathb-cc` assembles x86-64 code | qbe |

`-fsanitize=address` is not in the table: it takes Path B by default, with the gcc fallback.
## Going back

`--backend=qbe` for one command, or `NFCXX_BACKEND=qbe` for a whole shell, restores the old default.

## Known gaps behind the choice

The rest of the work is listed in `docs/notes/library-suite-results.md` (STL route survey: Path B timeouts and refusals)
and in the CI notes: the Path B suites run only when their paths change, and no CI job runs the default driver under
Path B on arm64 or macOS.
