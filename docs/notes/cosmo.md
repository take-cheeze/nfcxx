# Cosmopolitan (`nfcxx --cosmo`)

[Cosmopolitan](https://github.com/jart/cosmopolitan) builds APE binaries: one file that runs on Linux, macOS, Windows and
the BSDs. `nfcxx --cosmo` compiles with `cosmocc` as the C compiler instead of the host's. It is the gcc backend's
path with a different compiler, so the first step is C; C++ comes after.

```
scripts/setup-cosmo.sh                      # fetches cosmocc 4.0.2 (GitHub release) into build/cosmocc; sha256-checked
./nfcxx --cosmo hello.c -o hello.com        # --backend=gcc is implied; NFCXX_COSMOCC=path overrides build/cosmocc
tests/cosmo/run.sh
```

## Status

| Part | State |
| --- | --- |
| `--cosmo` option, `NFCXX_GCC` set to cosmocc, refusals (qbe backend, missing cosmocc) | done |
| The C compile and the link run cosmocc (`tests/cosmo/run.sh`, with a stand-in cosmocc that logs and runs gcc) | done |
| `scripts/setup-cosmo.sh` (fetch cosmocc 4.0.2 from the GitHub release, sha256-checked) | done; cosmo.zip is not used because the CI runners and the sandbox could not reach it |
| A real cosmocc build of a C program and its run | done locally with cosmocc 4.0.2 (GCC 14.1): `tests/cosmo/run.sh` passes and the output is an APE binary (`MZqF` header) |
| C++ (`.cpp`) | not started (see below) |

## What the driver changes

- `--cosmo` sets the backend to gcc and `NFCXX_GCC` to the cosmocc binary. `scripts/gcc-cc` runs `NFCXX_GCC` for the
  C compile, which is where the EDG output and the C inputs are compiled.
- The C-only link and the C input compile use `${NFCXX_GCC:-gcc}`, where they used a literal `gcc`. Without `NFCXX_GCC`
  they are unchanged.
- `ensure_tool` creates its output directory. A fresh checkout has no `build/`, and the lock `mkdir` used to fail there,
  so every run waited for the lock until it timed out.

## Not yet covered

- **C++.** The hosted link uses EDG's runtime (`libC.a`), the EH shim, and libstdc++ headers from the host `g++`. All
  of these are built for glibc. A cosmo C++ build needs them rebuilt with cosmocc, and libc++ headers from cosmo.
- **The assembler.** `scripts/gcc-cc` assembles the weak-symbol output with the host `as`. That is ELF on x86_64 Linux,
  which cosmocc links, but it is not checked against cosmocc's own assembler.
- **Runtime-loaded features.** APE binaries are static. `lib/poly` (Ruby, Lua, Python, JS, Go), `lib/ffi`, `lib/eval`,
  `--bundle-libs` and the CUDA paths depend on dynamic loading or shared libraries and will not work with `--cosmo`.
- **Other platforms.** Only Linux x86_64 is the development host here. The APE output is not run on macOS or Windows yet.

## Path B (`NFCXX_PATH=b --cosmo`), in progress

- **Done:** `--cosmo` with `NFCXX_PATH=b` selects Path B. `pathb-cc` assembles with cosmocc (`NFCXX_GCC`), the Path B
  link uses cosmocc and `-lC -lc++ -lm` (no glibc-only libraries), and `pathb-ldrt` builds `libnfcxxld.a` with cosmocc
  into `build/pathb-ldrt-cosmo`. The C++ headers are cosmo's libc++ (`include/third_party/libcxx`) and its C library
  (`include`), named in `NFCXX_SYS_INCLUDES`, because `cosmoc++` prints no include list for `host_sys_includes`.
  Predefines `__COSMOPOLITAN__`, `__COSMOCC__`, `__FATCOSMOCC__` are added, and the GNU version is cosmo's GCC 14.1.0 (140100).
- **Blocked:** EDG cannot parse cosmo's libc++ and libc headers. Errors: `__has_feature`/`__has_builtin` in constant
  expressions (`__config`), `bool32` and `libcesque` in `libc/calls/calls.h` (defined by cosmo's `libc/c.inc` and
  `libc/cxx.inc`, which cosmo's own build includes), and the libc++ namespace macros. `NFCXX_DIALECT=clang` does not fix it.
  The next step is either EDG support for those builtins plus the cosmo `.inc` headers, or a smaller libc++ config.
- **Not done:** EDG's `libC.a` and the EH shim still come from the host build, so the link would not work even when
  the headers parse. `lib/ehshim` is written against libstdc++'s exception layout (static_asserts on its size).
- Host Path B and the gcc backend are unchanged (regression-checked).
