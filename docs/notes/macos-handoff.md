# Handoff: developing nfcxx on macOS

Written for a macOS machine (Apple silicon, the `macos-15` CI image). It covers where the work stands, how to build and
test here, what differs from Linux, and what is open. Everything below names the script or test that checks it.

## Where things stand

- Designated branch: `claude/cross-compilation-support-0tgokq`, which is `main` plus this note.
- Merged to `main` this session:
  - PR #320: `nfcxx --freestanding --emit-c --target=NAME` (EDG layout for a target), the char-signedness fix for the
    Linux ABIs, the MinGW-built `win64` macro table (`scripts/win-predef.sh`), and `tests/target/run.sh`.
  - PR #321: `.github/workflows/emulators.yml` (nightly qemu-user and wine checks) and nightly Hexagon.
- `docs/notes/freestanding.md` has the "Targets" and "Windows" sections. `docs/README.md` has the status matrix.

## Set up

```
git clone https://github.com/take-cheeze/nfcxx && cd nfcxx
git checkout claude/cross-compilation-support-0tgokq
git submodule update --init --recursive          # 3rd/edg, 3rd/qbe, 3rd/cproc
brew install ccache ninja cmake                  # as the macos-suites CI job does
ruby --version && (rake --version || gem install rake)
scripts/setup-edg.sh                             # EDG front end (macOS branch: cmake preset macos-arm, clang base)
scripts/setup-qbe.sh                             # only for the default qbe backend
./nfcxx hello.cpp -o hello && ./hello            # qbe backend; NFCXX_BACKEND=gcc uses clang's C path
```

`setup-edg.sh` on macOS copies `bases/cmake-native/macos-arm/clang`, makes `EDG_C_TO_OBJ_COMPILER` follow `NFCXX_CC`, strips
the universal `-arch arm64 -arch x86_64` flags, and uses `nm -og -fMacOSX64` for the prelinker. Those edits are in that
script; do not hand-edit the base.

To run the checks that CI runs on macOS (`.github/workflows/ci.yml`, job `macos-suites`):

```
tests/run.sh
tests/lib/run.sh
tests/target/run.sh
tests/builtins/run.sh
tests/trace/run.sh
tests/c/run.sh && tests/c/cc-mode.sh
tests/cxx-driver/run.sh
```

Run them once with `NFCXX_BACKEND=gcc` and once with the default (`qbe`), as CI does.

## What is different on macOS

- The EDG base has only the `macos_arm64` table (`lib_macos_arm64`). `tests/target/run.sh` therefore skips the Linux and
  Windows targets with a message and still runs the refusal checks. This is intended, and it is why the macOS job no longer
  fails on those probes (commit `51ecac3`).
- Apple's sizes come from `src/defines_macosx.h` in EDG, chosen at EDG build time. A target name such as `--target=linux_aarch64`
  does not select them. Here `long double` is 8 bytes on arm64 and 16 on x86-64 macOS.
- The Darwin branches are in `nfcxx` (two `uname` checks), `scripts/qbe-cc` (four), `scripts/sret.sh` (the arm64 result-pointer
  thunks, with `xcrun --sdk macosx --show-sdk-path` for the libc++ exports), and `scripts/setup-edg.sh`. The QBE and cproc
  Apple patches are under `scripts/*apple*.patch` and `scripts/cproc-darwin-ldouble.patch`.
- The C++ library is libc++ on macOS (`-lc++`), not libstdc++. Mach-O symbols carry a leading `_`; `qbe-cc` passes
  `--sym-prefix=_` to `weak-symbols.rb`.
- `scripts/win-predef.sh` is only called when MinGW-w64 is installed. On macOS nothing calls it.

## Open items, by priority

1. **Nothing here runs the macOS output on a Mac except the CI job.** Run `tests/run.sh` and friends locally before relying on
   a change.
2. **EH and template runtime (`libC.a`).** EDG builds its C++ runtime on the host. Programs that throw, or that use templates
   that need the prelinker, do not link through `--emit-c` for any non-host target. On macOS the `eccp` path works, so the
   open problem is only cross targets.
3. **Cross-compiling to macOS from Linux** is not done. It needs an Apple SDK (for headers and `libSystem.tbd` / `libc++.tbd`
   stubs), `clang --target=arm64-apple-macos` with `-isysroot`, `ld64.lld` or Apple's `ld64`, and named macOS target tables
   in EDG (the sizes are compiled in). The SDK is subject to Apple's license. Building libSystem from Apple's open-source code
   is not needed for a link; the SDK's `.tbd` stubs are the reference for the symbol list.
4. **EDG `win64` `long double` is 8 bytes; MinGW's is 16.** A compiled-in EDG constant. Needs a change in the EDG fork,
   `take-cheeze/edg-compiler`.
5. **`tests/lib` programs do not run under qemu or wine**, because of item 2.

## Repository rules that apply

- Develop on the designated branch and push it. Pushes must be fast-forward. No force push: a force push was refused by the
  permission check during this session.
- Do not open a PR unless the user asks for one. Commit messages end with the `Co-Authored-By` and `Claude-Session` lines,
  without model names.
- GitHub Actions `schedule:` runs only from the default branch, so nightly changes only take effect once merged to `main`.

## Where to look first

- `docs/notes/freestanding.md` (Targets, Windows)
- `scripts/setup-edg.sh`, `scripts/win-predef.sh`, `scripts/sret.sh`, `scripts/qbe-cc`
- `tests/target/run.sh` and the `tests/target/*_layout.cpp` and `win64_probe.cpp` probes
- `.github/workflows/ci.yml` (`macos-suites`), `emulators.yml`, `hexagon.yml`
