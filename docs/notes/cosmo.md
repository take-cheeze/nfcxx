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

## Path B (`NFCXX_PATH=b --cosmo`), hello world links and runs

`NFCXX_PATH=b ./nfcxx --cosmo hello.cpp -o hello` builds a static x86_64 ELF with cosmo's libc++ and runs it (`pathb host ok`).
The output is not yet an APE binary (see "Not done").

- **Front end:** cosmo's libc++ (`include/third_party/libcxx`) and C library (`include`) are named in `NFCXX_SYS_INCLUDES`,
  because `cosmoc++` prints no include list. Predefines `__COSMOPOLITAN__`, `__COSMOCC__`, `__FATCOSMOCC__` are added, and
  the GNU version is cosmo's GCC 14.1.0 (140100). Path B also gets cosmo's own forced include `libc/integral/normalize.inc`
  (what cosmo's build force-includes; it defines `libcesque`, `bool32`, `__static_yoink`) and `-D__has_feature(x)=0`, which
  libc++'s `__config` needs. Found with the fork of the EDG investigation; no EDG source change was needed.
- **Assembly:** cosmocc does not take `.s` input, so `pathb-cc` assembles the QBE output with the host `as` (as `gcc-cc`).
- **Link:** the x86_64 cosmo driver links with cosmo's `ape.lds`, `ape.o`, `crt.o` and `-lC -lcxx -lc -lcosmo -lm`
  (the fat `cosmocc` link wants an aarch64 companion per object, which Path B does not produce). The EH shim is left out
  under `--cosmo`: it interoperates with libstdc++.so, and cosmo links libc++ only.
- **Runtime:** `pathb-ldrt` builds `libnfcxxld.a` with cosmocc (`build/pathb-ldrt-cosmo`).
- `pathb-dump` takes `-include FILE` (EDG's `--preinclude`).
- The gcc backend path is unchanged: `tests/cosmo/run.sh` passes with the real cosmocc (APE output).

### Not done

- **APE output.** The Path B link produces an ELF. Cosmo's APE packaging (`apelink`) needs the zip section fixed up by
  `fixupobj` (cosmo's `tool/build/fixupobj.c`, which is written against cosmo's own libc), so that is the next step.
- **libC.a.** The EDG runtime is still the host build; it links here, but cosmo's C++ runtime behavior (exceptions,
  `operator new`) is not tested. `tests/pathb-qbe/hosted.sh` has not been run with `--cosmo`.
- **Coverage.** Only the hello-world program is tested.
