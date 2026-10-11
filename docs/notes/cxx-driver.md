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
| `-Wl,*` | passed to the link |
| `-fexceptions`, `-fwrapv`, `-fno-strict-aliasing` | accepted: EDG always lowers exceptions; the C side already gets the other two |
| `-fvisibility=*`, `-fvisibility-inlines-hidden` | ignored, as `nfcc` ignores them (`docs/notes/realworld.md`). They change the exports of a `-shared` object; that is the one place this could matter |
| `-fPIC`, `-fPIE`, `-pie`, `-rdynamic` | passed to the C compile and the link |
| `-pthread` | passed to the C compile and the link |
| `-isystem DIR`, `-isystemDIR` | a system include directory, after the host's own |
| `-lNAME` | `--c_to_obj_lib=NAME`: the host linker resolves it. eccp's own search (`-l` in its prelinker) looks only in `-L` directories and `/lib`, `/usr/lib`, which misses a multiarch `libm` |
| `-E` (with `-P`, `-o`, `-x c++`, and `-` for a source on stdin) | the host C++ compiler preprocesses, as `nfcc` does for C; mruby's presym step and CMake's GLES3 header probe run the compiler this way |
| `-include FILE` | EDG's `--preinclude`: the header is found through the include paths and its macros are visible (Effekseer's `-include EGL/egl.h`) |
| `-c` with `-MD`/`-MMD` and `-MF`/`-MT`/`-MQ`/`-MP` | the host preprocessor writes the dependency file (`-M`/`-MM`), as `nfcc` does; a dependency option without `-c` is refused |

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
