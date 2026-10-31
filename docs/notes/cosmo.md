# Cosmopolitan (`nfcxx --cosmo`)

[Cosmopolitan](https://github.com/jart/cosmopolitan) builds APE binaries: one file that runs on Linux, macOS, Windows and
the BSDs. `nfcxx --cosmo` compiles with `cosmocc` as the C compiler instead of the host's. It is the gcc backend's
path with a different compiler, so the first step is C; C++ comes after.

```
scripts/setup-cosmo.sh                      # fetches cosmocc into build/cosmocc (COSMOCC_SHA256 pins the zip)
./nfcxx --cosmo hello.c -o hello.com        # --backend=gcc is implied; NFCXX_COSMOCC=path overrides build/cosmocc
tests/cosmo/run.sh
```

## Status

| Part | State |
| --- | --- |
| `--cosmo` option, `NFCXX_GCC` set to cosmocc, refusals (qbe backend, missing cosmocc) | done |
| The C compile and the link run cosmocc (`tests/cosmo/run.sh`, with a stand-in cosmocc that logs and runs gcc) | done |
| `scripts/setup-cosmo.sh` (fetch the release zip, optional sha256) | written, not run: cosmo.zip is unreachable from the development sandbox |
| A real cosmocc build of a C program and its run | not yet verified; `tests/cosmo/run.sh` runs it when cosmocc is present |
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
