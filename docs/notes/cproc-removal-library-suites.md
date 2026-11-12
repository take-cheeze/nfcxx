# Library, ABI and driver suites on Path B (cproc removal, wave 2, workstream C)

These suites no longer pin the qbe backend; on x86-64 Linux they run Path B (`NFCXX_BACKEND=pathb`, hard errors) next to gcc.
A case that does not work on Path B stays on qbe and carries a `QBE-ONLY: <reason>` marker in its script
(`git grep QBE-ONLY tests/`): that list is what still needs cproc.

| Suite | Now | Left on qbe (QBE-ONLY) |
|---|---|---|
| tests/realworld/run.sh (tinyxml2), run_json.sh, run_doctest.sh | gcc, Path B | none |
| tests/realworld/run_coreclr_gc.sh | gcc, Path B | `handletable.cpp` (QBE rejects Path B's output: unexpected phi instruction), compiled by qbe |
| tests/realworld/run_lua.sh, run_lua_make.sh | gcc, Path B | none (computed goto: docs/notes/pathb-computed-goto.md) |
| tests/realworld/run_mruby.sh, run_optcarrot.sh | qbe, gcc | Path B refuses mrbc.c (`parse_args: operator unsupported`) |
| tests/realworld/run_tinycc.sh | qbe, gcc | QBE: invalid type for first operand in add (xadd) |
| tests/realworld/run_astro.sh | qbe, gcc, Path B | none (the Path B gaps are in docs/notes/astro.md, "Path B") |
| tests/realworld/run_fmt.sh | gcc, Path B | none (`__builtin_ia32_addcarryx_u64`, used by `uint128_fallback::operator+=`, is lowered) |
| tests/realworld/run_sdcc.sh | unchanged | not run on Path B (needs flex and boost in the session that did this) |
| tests/sqlite/run.sh | qbe, gcc | QBE xadd issue on sqlite3.c |
| tests/poly/run.sh (+ setup-poly*.sh) | qbe, gcc | C libraries (mruby, Lua, QuickJS) refused as above; `ops.cpp` aborts (double free) on Path B |
| tests/ast/run.sh | qbe, gcc | engine.cpp aborts in "inlining of small functions" on Path B |
| tests/uop/run.sh, run_poly.sh | qbe, gcc | nfcuop_lower.cpp: unexpected phi instruction |
| tests/int128, tests/sret, tests/determinism | Path B (+ gcc for sret) | none |
| tests/float-to-int | Path B | `classify.c`: `__builtin_fpclassify` ignores its five class arguments |
| tests/long-double-abi | qbe | both directions: Path B refuses a variadic call with a long double argument |
| tests/ehshim | gcc, Path B | none |
| tests/cxx-driver | gcc (default) | `NFCXX_BACKEND=pathb` fails 16 of 52 option checks: `-isystem DIR`, `-include FILE`, dependency files, `-fno-rtti` refusal, `--keep-intermediates`, the object cache |

tests/mruby: qbe-prep.sh, qbe-asm.sh, weak-symbols test cproc's own preprocessing and are deleted with cproc.
