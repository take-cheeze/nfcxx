# Removing cproc

cproc (`3rd/cproc`, the C front end of the qbe backend: EDG's generated C -> cproc -> QBE) is being replaced by Path B (EDG ->
typed IR -> QBE IL, no generated C). QBE stays. This note is the checklist: what goes when cproc goes, who still uses it, what
replaces each use and what is left. A consumer is moved when its tests run on Path B (or gcc), not when it is merely possible.

State as of the PRs named below (#976, #977, #980-#983, #989, #992 and the QBE `xadd` fix #962 are merged).

## What is deleted at the end

- `3rd/cproc` and the cproc part of `scripts/setup-qbe.sh` (QBE is still built there).
- `scripts/qbe-cc`, `scripts/qbe-prep`, `tools/qbe-prep/`, `scripts/qbe-try`, `scripts/qbe-file-check.sh`, `scripts/cil-cc` (a wrapper of `qbe-cc`).
- The cproc patches: `scripts/cproc-aligned-attr.patch`, `cproc-apple-driver`, `cproc-apple-predefines`, `cproc-apple-valist`,
  `cproc-atomic-builtins`, `cproc-darwin-ldouble`, `cproc-dollar-ident`, `cproc-unprototyped-fnptr`.
- The workarounds that exist only for cproc: `scripts/quickjs-cproc.patch`, `scripts/lua-cxx-novolatile.patch`,
  `scripts/mruby-cxx-novolatile.patch`, and the cproc-specific lines of `scripts/setup-poly*.sh`, `setup-sqlite.sh`,
  `setup-mruby.sh`, `mruby-rt-config.rb`, `mruby-tool-config.rb`, `mrustc-nfcc.sh`, `ggml-sycl-lib.sh`, `selfhost-cpfe.sh`.
- The `qbe` backend itself (`--backend=qbe`, `NFCXX_BACKEND=qbe`, `nfcc`'s `qbe` backend) and `docs/notes/cproc-nfcxx.md`.
- Tests that are about cproc: `tests/mruby/qbe-prep*.sh` and their taps, the `MACOS-XFAIL-qbe` markers of `tests/c`.

Check at the end: `grep -rIl 'cproc\|qbe-cc\|qbe-prep'` outside `docs/` and git history finds nothing.

## Consumers

| Consumer | Replacement | State |
| --- | --- | --- |
| `./nfcxx` default on x86-64 Linux, C++ and C | Path B, gcc on a file it does not build | done |
| `--freestanding` on x86-64 Linux | Path B (`pathb-dump --freestanding --eh-runtime`) | #976 merged |
| C that Path B refused: unions by value, `_Float16`, inline asm, return/frame address, `cleanup`, `section`, case ranges, flexible array initializers | Path B lowerings | #980, #981, #982, #983 merged. Left in `tests/c` (`XFAIL-pathb`): `asm goto` and any other marker still present |
| `nfcc` (cc for make, CMake, autoconf, the kernel) | `NFCXX_BACKEND=pathb` | opt-in since #977. It takes the kernel's option set (`-nostdinc`, `-isystem`, `-funsigned-char`, `-fshort-wchar`, `-ffreestanding`, `-mno-sse` checked, codegen options dropped; other semantic options make that compile gcc's: docs/notes/linux-kernel.md). The default stays qbe until the kernel is built with it |
| Linux 6.8 tinyconfig kernel (`scripts/linux-qemu.sh`, `linux-qemu.yml`), 615 C files | `nfcc` on Path B | **570 of 615 build** (538 before the `claude/pathb-kernel-refusals` branch): docs/notes/linux-kernel.md, "Measured". The rest is inline asm and the real-mode boot code |
| C++ modules (default backend was qbe) | Path B (the `-c` compile passes the module options) | #989 merged; `--backend=qbe` with modules still uses cproc |
| qbe-backend ASan (cproc's own checks, branch `nfcxx-asan-combined`) | Path B ASan (the default since #892) | #992 merged: `-fsanitize=address --backend=qbe` is an error; the cproc ASan code is dead and goes with cproc |
| CIL (.NET) backend: `cil-cc` is `qbe-cc` | `scripts/pathb-cil` for C | #993 open |
| Tests and CI legs pinned to qbe, C++ language suites | Path B and gcc | #990 open |
| Tests and CI legs pinned to qbe, library, ABI and driver suites | Path B and gcc | #994 open |
| Third-party C built through nfcc's qbe route: Lua, QuickJS, SQLite, mruby, mrustc, ggml | nfcc on Path B or gcc, then drop the cproc workarounds | not started; follows the `nfcc` default |
| macOS arm64 and every non-x86-64 host (default backend is qbe there; cproc `-t aarch64-apple` and the `cproc-apple-*` patches) | Path B on those hosts | another session; no CI job runs the default driver under Path B on arm64 or macOS |

## Order

1. Wave 2 PRs merge (#990, #993, #994 open); each leaves a `QBE-ONLY: <reason>` marker for what does not work on Path B, which is
   the exact list of what still needs cproc (`git grep QBE-ONLY`). So far, from the PR descriptions:
   - `tests/builtins/bit_g.cpp`: Path B with `--gnu-version=140000` reports `__builtin_clzg` undefined; `integer_seq.cpp` (#990) needed `--dialect=clang` on Path B: done, `scripts/pathb-dump` gives
     EDG `--clang --clang_version=N` as the qbe path does, `nfcxx` and `scripts/pathb-cc` pass `--dialect=clang` on, and the QBE-ONLY marker is gone.
   - `tests/poly`: the mruby, Lua and QuickJS C builds are refused (with `POLY_LANGS="python ast"` host.cpp and ops.cpp pass on Path B; the
     `ops.cpp` abort was a function-local static with a constant initializer whose destructor was registered at every call, and a
     one-element trailing array checked against its bound).
   - `tests/ast`: engine.cpp and tier.cpp pass on Path B (the SIGABRT was a null check under the lvalue adjustment of a derived-to-base
     pointer conversion); the case `inline_loops` still overflows the 8 MB stack on Path B, whose frames are several times gcc's.
   - `tests/long-double-abi` runs on Path B and gcc (a variadic call with long double arguments and result goes through a
     per-shape call thunk); `tests/cil/errors/variadic_def.c` is Path B's own refusal, `cil-cc` does not fall back to cproc for it.
   - CIL route (#993): of 63 single-file `tests/c` programs 36 build and pass, 27 are refused on Path B (10 asm, 4 runtime helpers, 4
     unlowerable, 2 `_Float16`, 2 over-aligned and singles); every `tests/cil` program runs, one of them through the cproc fallback.
   - ASan (#992): Path B does not detect the two setjmp-return scope escapes (gcc does not either), so `tests/poly/asan-go.sh` is gcc-only.
2. Measure the kernel on `nfcc` Path B (`KCC=nfcc NFCXX_BACKEND=pathb NFCXX_PATHB_FALLBACK=gcc NFCXX_PATHB_LOG=...`: nfcc no longer refuses the kernel's options, so the run is possible; the 570 of 615 is the replay with the options dropped, this run counts the options honoured, and the files that fall to gcc for `-ftrivial-auto-var-init=zero` or a refused unit). It decides the size of the remaining Path B gaps and whether `nfcc` can default to Path B
   (with gcc for a file Path B refuses).
3. Flip `nfcc` and move the third-party C builds; remove their cproc workarounds.
4. Path B (or gcc) on non-x86-64 hosts, so that no default selects qbe.
5. When no default, no CI leg and no test needs it, delete the files above in one PR and run the check at the top.
