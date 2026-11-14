# nfcxx as the C++ compiler of a build system

`nfcxx` compiles one command line at a time, for a build system that runs it as `CXX` (CMake, ninja, mruby's rake
build). Before this note its option loop passed every option it did not know to `eccp`, which rejected them, so a
CMake compile line failed on its first translation unit. `tests/cxx-driver/run.sh` (CI: `ci.yml`) covers the options
below, on the gcc backend.

## Options

| Option | Handling |
| --- | --- |
| `-std=gnu++NN` | as `-std=c++NN`; GNU and strict modes differ in the dialect, which `--dialect` selects |
| `-W*`, `-w` | dropped: warnings do not change the object code (no `-Werror`) |
| `-pipe` | dropped: the stages talk through pipes instead of temporary files; the output is the same (ninja's `configure.py` passes it) |
| `-Wl,*` | passed to the host link as an EDG `--c_to_obj_option` (order-independent options such as `-Wl,-rpath,DIR`, `-Wl,-E`, `-Wl,--gc-sections`). eccp puts its `--c_to_obj_option` items before every object and archive, so the order-dependent options cannot stay where they are. `--no-as-needed` (alone or as `-Wl,--no-as-needed,LIB,...`, find_package(Torch)'s form) becomes one `--no-as-needed` for the whole link, its items stay inputs in place, and the `-Wl,--as-needed` that closes such a span is dropped: every library is then kept in DT_NEEDED, which only adds entries; `-Wl,--as-needed` alone applies to the whole link. The others (`--whole-archive`/`--no-whole-archive`, `--start-group`/`--end-group`, `-Bstatic`/`-Bdynamic`, `-Wl,--as-needed,...`) are refused with exit 2 for C++ inputs. A file the link writes (`--dependency-file=`, CMake 4's relative `CMakeFiles/T.dir/link.d`; `-Map=`) is made absolute when its directory exists, since eccp links in a temporary directory. Before this change every `-Wl,*` was rejected by eccp ("unknown option"). Test: `tests/cxx-driver/run.sh` |
| `-fexceptions`, `-fwrapv`, `-fno-strict-aliasing` | accepted: EDG always lowers exceptions; the C side already gets the other two |
| `-fvisibility=*`, `-fvisibility-inlines-hidden` | ignored, as `nfcc` ignores them (`docs/notes/realworld.md`). They change the exports of a `-shared` object; that is the one place this could matter |
| `-fPIC`, `-fPIE`, `-pie`, `-rdynamic` | passed to the C compile and the link |
| `-pthread` | passed to the C compile and the link |
| `-isystem DIR`, `-isystemDIR` | a system include directory, after the host's own |
| `-I DIR`, `-D NAME`, `-U NAME` (separate argument, as mrustc's Makefile writes them) | joined to `-IDIR` etc. The joined form was the only one the host dependency pass (`-MMD`) saw, so with the separate form it ran without the include path and failed ("No such file"). Test: `tests/cxx-driver/run.sh` |
| `-lNAME` | `--c_to_obj_lib=NAME`: the host linker resolves it. eccp's own search (`-l` in its prelinker) looks only in `-L` directories and `/lib`, `/usr/lib`, which misses a multiarch `libm` |
| `-E` (with `-P`, `-o`, `-x c++`, and `-` for a source on stdin) | the host C++ compiler preprocesses, as `nfcc` does for C; mruby's presym step and CMake's GLES3 header probe run the compiler this way |
| `-include FILE` | EDG's `--preinclude`: the header is found through the include paths and its macros are visible (Effekseer's `-include EGL/egl.h`) |
| `-c` with `-MD`/`-MMD` and `-MF`/`-MT`/`-MQ`/`-MP` | the host preprocessor writes the dependency file (`-M`/`-MM`), as `nfcc` does; a dependency option without `-c` is refused |

### Flags and environment variables

Options are flags; the environment variables are the fallback (a build system or script that cannot change a command line sets one
once), and the flag wins when both are given. Tool and host locations stay variables, as `CC=` does.

| Flag | Variable (fallback) | What it does |
| --- | --- | --- |
| `--backend=pathb\|qbe\|gcc` | `NFCXX_BACKEND`; `NFCXX_PATH=b` is `--backend=pathb` | the backend; `--backend=pathb` is Path B by name (no fallback to gcc) |
| `--ir-opt=LIST` | `NFCXX_IR_OPT` | the Path B IR passes (`docs/notes/pathb-ir-passes.md`); `--ir-opt=off` turns the .cu device passes off |
| `--eh-unwind`, `--no-eh-unwind` | `NFCXX_EH_UNWIND=1` | cleanups of unwound frames run in the system unwinder (gcc and qbe backends) |
| `--no-eh-shim` | `NFCXX_EHSHIM=0` | link without the EH shim |
| `--instantiate=used\|auto` | `NFCXX_INSTANTIATE` | where templates are instantiated |
| `--cache=DIR`, `--cache-log=FILE` | `NFCXX_CACHE`, `NFCXX_CACHE_LOG` | the compile cache, below |
| `--keep-intermediates` | `NFCXX_KEEP_INTERMEDIATES=1` | keep the temporary directory of a compile and link |
| `--trace=FILE`, `--time-log=FILE` | `NFCXX_TRACE`, `NFCXX_TIME_LOG` | `docs/notes/tracing.md` |
| `-fuse-ld=NAME` | `NFCXX_LD=NAME` | the linker (`ld.NAME` on PATH) |
| `--promote-slots=on\|off`, `--unroll=on\|off`, `--struct-slots=on\|off` | `NFCXX_PROMOTE_SLOTS`, `NFCXX_UNROLL`, `NFCXX_STRUCT_SLOTS` (0 or 1) | optimizations of .cu device code (`docs/notes/gpu.md`) |
| `--pathb-c=gcc` | `NFCXX_PATHB_C=gcc` | with Path B, the .c inputs go through `gcc-cc` |
| `--dialect=`, `--obfuscate-kernels`, `--cuda-driver=`, `--module-dir=` | `NFCXX_DIALECT`, `NFCXX_OBFUSCATE_KERNELS`, `NFCXX_CUDA_DRIVER` | as before |

Stay variables: `NFCXX_GCC`, `NFCXX_CC`, `NFCXX_CXX`, `NFCXX_COSMOCC`, `NFCXX_SYSTEM_PATHS`, `NFCXX_SYS_INCLUDES`, `NFCXX_K1OM_ROOT`,
`NFCXX_MACOS_SYSROOT`, the CUDA tuning (`NFCXX_SM`, `NFCXX_CUDA_*`, `NFCXX_INLINE_DEVICE`, ...) and the SYCL build's (`NFCXX_SYCL_*`).
Between our own scripts the settings are flags too: `scripts/pathb-cc` (`--asan`, `--safe-pointers`, `--sanitize=`, `--ir-opt=`,
`--emitter=`, `--keep=`), `scripts/pathb-dump` (`--ir-loc`, `--ir-scopes`, `--borrow`, `--sanitize=`, `--overflow=`, `--cuda-device`),
`scripts/pathb-ssa-build` (`--qbe=PATH`) and `scripts/qbe-cc` (`--c-input`, `--eh-unwind`, `-fsanitize=address`). The front end (`be/nfcxx_ir.c`)
itself reads `NFCXX_IR_LOC`, `NFCXX_IR_SCOPES`, `NFCXX_IR_SANITIZE`, `NFCXX_PATHB_BORROW` and `NFCXX_PATHB_MODE` from its environment; `pathb-dump` sets
them from its flags, so only that one script exports them.

### Compile cache (`--cache=DIR`)

Opt-in: with `--cache=DIR` (or `NFCXX_CACHE=DIR`; the flag wins), a `-c` compile of one C++ source with `-o OBJ` is kept under `DIR/objects/<key>`, and an identical
compile later copies the object back with its `<stem>.ti` and `<stem>.ii` (the link reads those records beside the object). The key
covers the command as given, the absolute output path (the prelinker records it in the `.ti`), the working directory, the source
and each header the host preprocessor lists (hashed), every `NFCXX_*` variable, the driver and `scripts/` (and `tools/weak-symbols`, `tools/qbe-prep`), the EDG and QBE binaries,
and the host compilers' versions. Not cached: `.cu` (its device image is, below) and C inputs, `-E`, `-MD`, several sources in one command, and an `-o` without
an extension. A header whose path has a space is not tracked, so its change would not invalidate the key. Test 15 of
`tests/cxx-driver/run.sh` covers a hit that links, and a changed header.
The same cache serves the Path B route (the default on x86-64 Linux, `scripts/pathb-cc`): a Path B key adds `backend: pathb` and
the Path B front end (`PATHB_CPFE`, the files of `PATHB_BASE`), so a Path B object and a gcc-route object never share an entry,
and a Path B entry holds the object only. `tests/nfcxx-cache/run.sh` covers both routes.

A `.cu` compile is not kept as an object, but its device image is: under `DIR/cu-device/<key>`, the device IR and the
PTX modules with their cubins. The key covers the device unit the rewriter writes and its kernel list, the `-D`/`-U`
options and the toolkit version macros, the SM, `NFCXX_CUDA_JIT` and the module budgets, the device front end
(`cpfe`, `scripts/pathb-dump`, its base directory), `pathb-ptx-emit` and the ptxas version. A hit skips the device
front end, the emitter and ptxas; the rewriter, the embed step and the host compile still run. On ggml-cuda (RTX 2060
machine) mmvq.cu went from 249 s to 23 s (ptxas was 222 s of it), while binbcast.cu is almost all host compile: two of about
350 s each (the second pass, for its kernel instances, runs with the cache off), and about 8 s of device stages. `--cache-log` logs these lookups as `== F.cu device unit`. `tests/cuda/run.sh`
covers a miss, a hit whose program runs, and a changed kernel.

With `--cache-log=FILE` (or `NFCXX_CACHE_LOG=FILE`) as well, each lookup appends its key inputs (the bytes that are hashed, one block per compile headed by `== OUT (SRC)`), then `key KEY`, then `hit` or `miss`. Diff the input blocks of a miss against the last hit for the same output to see which input changed. The cache and log options (and `--time-log`, `--trace`) are left out of the key, so logging never causes a miss.

#### Remote tier: the GitHub Actions cache (`NFCXX_CACHE_REMOTE=gha`)

`NFCXX_CACHE_REMOTE=gha` keeps the same objects in the GitHub Actions cache, one entry per key, the way sccache's GHA
backend does (not as one directory saved by `actions/cache`). A local miss is looked up remotely and a hit is copied to
`DIR/objects/<key>`; a new local entry is stored remotely after it is written. `NFCXX_CACHE` is still the local side
(without it, a temporary directory is used). The entry is a tar of `obj`, `ti` and `ii`, under the key `nfcxx-<key>`
with the version the SHA-256 of `nfcxx-cache-v1` (a change to that namespace drops every entry).
`scripts/nfcxx-cache-gha.py` (standard library only) makes the calls: CreateCacheEntry, PATCH to the signed upload URL
with `Content-Range`, FinalizeCacheEntryUpload, GetCacheEntryDownloadURL and GET. It needs `ACTIONS_RESULTS_URL`,
`ACTIONS_RUNTIME_TOKEN` and `ACTIONS_CACHE_SERVICE_V2` set, which a workflow step has when it runs with the cache
enabled. A remote failure is a miss, or a store that did not happen, with a note on stderr: a build does not fail for its
cache. `NFCXX_CACHE_REMOTE` is left out of the key, and the CUDA second pass runs with it off.

Scope: only the object cache. A `.cu` device image (`DIR/cu-device`) stays local. The protocol is checked against a mock
of the service in `tests/gha-cache/run.sh` (the requests, the answers, immutability, path safety, and the driver's two
functions taken from `nfcxx`). The live service is not reachable from the development sandbox, so the first run in a
workflow is the test of the real one. The GitHub Actions cache is 10 GB per repository and is shared with sccache and
`actions/cache`; the workflows do not set `NFCXX_CACHE_REMOTE` yet.

Refused (eccp says `unknown option`): `-fno-rtti`, `-fno-exceptions`, and every other option not in the table, since
each of them would change the meaning of the code or is not implemented.

## The rpg-maker-clone desktop target, built with nfcxx as CXX (2026-10-10)

Recipe (`CMakeLists.txt` at the repo root; `build_config.rb` for mruby): `cmake -G Ninja`, SDL2 and SDL2_mixer dev
packages, EGL/GLES headers (Effekseer's GL backend), `ruby` with `rake` and `gperf`, the submodules at their pins
(`3rd/mruby`, `lvgl`, `quickjs`, `uni-algo`, `effekseer`, `ng-log`, `gflags`, `stb`, `inicpp`, `mruby-*`), and the
two Unicode tables `$cp932_table` and `$jis0208_table` (`scripts/native-build-without-nix.bash`, hashes checked).
`CC=nfcc` for C, `CXX=nfcxx` for C++, `NFCXX_BACKEND=gcc`. The reference build with gcc 13 completes.

The first failures, with the driver as it was before this change, were: every C++ translation unit failed on an option
of the table above (`-pthread`, `-MD`, `-isystem`, `-std=gnu++17`, `-E`, `-fPIE`), and the mruby host build failed on
`-E`. After the driver change:

| Cause | Where | Example | Class | Status |
| --- | --- | --- | --- | --- |
| Driver options (table above) | every C++ TU | `eccp: unknown option: -pthread` | bug (driver interface, undocumented) | fixed on `claude/cxx-driver-build-flags` |
| `-lm` on the link | mruby `mrbc` | `library "m" does not exist` | bug | fixed (same branch) |
| `-include EGL/egl.h` read as a second source | Effekseer `EffekseerRendererGL.*.cpp` (12 TUs) | `eccp: cannot compile additional non-modules files` | bug (driver) | fixed (same branch) |
| CMake's GLES3 probe, `CXX -E -x c++ -` with the source on stdin, failed; GLES3 looked absent and Effekseer was left out | `CMakeLists.txt` (the probe), so the link lacked `libEffekseer` (undefined `Effekseer::` symbols) | `undefined reference to 'Effekseer::Matrix44::Matrix44()'` | bug (driver) | fixed (same branch) |
| CMake `POSITION_INDEPENDENT_CODE` probes fail (`-fPIE`, `-pie`), so ng-log's `config.h` has `HAVE_PREAD`, `HAVE_MODE_T` unset and its sources fail (`mode_t` redeclared, `pread` linkage) | `3rd/ng-log/src/logging.cc:100,131` | `invalid redeclaration of type name "mode_t"` | bug, consequence of the driver | fixed (same branch); the probes must be rerun (`cmake -U HAVE_PREAD ...`) |
| `-fvisibility=hidden` on ng-log | 9 ng-log TUs | `eccp: unknown option: -fvisibility=hidden` | new gap (inconsistent with `nfcc`) | fixed (ignored; see table) |
| gcc 13's `immintrin.h` pulls `amxtileintrin.h`, which needs `__builtin_ia32_ldtilecfg`, which EDG does not know | `src/main.cxx`, `sdl_input.cxx`, `sdl_audio.cxx`, `voicevox_tts.cxx`, via `SDL_cpuinfo.h:111` | `/usr/lib/gcc/x86_64-linux-gnu/13/include/amxtileintrin.h:42: identifier "__builtin_ia32_ldtilecfg" is undefined` | new gap (x86 target builtins) | open. Workaround `-DSDL_DISABLE_IMMINTRIN_H` (the four TUs compile; checked) |
| GNU computed goto (`goto *optable[insn]`) with a `const void *` table; EDG requires `void *` | mruby `src/vm.c:1773` via `mrbc/src/vm-cxx.cxx`, 100+ errors | `in "goto *expr", expr must have type "void *"` | new gap; `realworld.md` covers the C path only | open. Workaround `MRB_USE_VM_SWITCH_DISPATCH` (the mruby host library and `mrbc` then build; checked) |

| Effekseer (C++ in `3rd/effekseer`, enabled once the GLES3 probe passes) | `3rd/effekseer/.../Effekseer.Manager.cpp` | `Internal error: assertion failed: dump_initializer_part: can't generate code for partial aggregate` (`3rd/edg/src/c_gen_be.c:8096`) | new gap (EDG's C back end cannot emit a partly initialised static aggregate). Not isolated to a line; this is the last failing TU, so `rpg_maker_clone` does not link | open |

Checked with the flags `build.ninja` records (`nfcxx` in place of `c++`): the four SDL-including `src/` TUs (with the
workaround), `src/log_*`, `window_title`, `error_dump`, the nine ng-log sources, the other Effekseer and
EffekseerRendererGL sources, and the 24 C++ sources of `mruby-rgss`, `mruby-mvjs`, `mruby-lcf`, `mruby-rpg2k` and
`mruby-wolf` (compiled with `src/main.cxx`'s flags plus the gems' include paths; the rake build was not used for
these). At the end of the session the nfcxx build of the desktop target had one failing step left (Effekseer.Manager),
so the executable was not linked. Not checked: the link and a run of `rpg_maker_clone`; the qbe backend (its
submodules were not initialised).

`CMAKE_CXX_STANDARD` is not set by the project, so `nfcxx` compiles it as `c++23` where `g++` would use `gnu++17`.
That is not a failure, but it is a difference to keep in mind.
