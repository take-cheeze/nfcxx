# Rust programs through mrustc and nfcxx's C pipeline

Status: **Rust programs run.** `tests/mrustc/run.sh` builds `hello.rs` and a `Vec`/iterator/`format!` program, and
both print the expected output. The program's own C, and the monomorphised generics it uses, are compiled by
nfcxx's C pipeline (cproc → QBE). The standard library is still mrustc's, built with gcc, and is linked in as
objects. Making the standard library go through the same pipeline is the next step (section 5).

The C backend is the fastest route to a running program: it already compiles the full Rust 1.90.0 standard library.
The other output, mrustc's monomorphised MIR (`-C codegen-type=monomir`), would need a new translator to nfcxx's IR
and is not started.

## 1. Pipeline

```
prog.rs --mrustc (-o prog)--> prog.c + prog_cmd.txt (mrustc's gcc command: the std objects and libraries)
prog.c --cc -E, the qbe-cc C-input preprocessing (host macros, -undef)--> pp.c
pp.c --scripts/mrustc-prep.rb--> prep.c, tail.s (asm-label trampolines)
prep.c --scripts/qbe-cc -c--> prog.o        (qbe-prep.rb, cproc, QBE, as)
tail.s --cc -c--> tail.o
prog.o tail.o + std objects (prog_cmd.txt) + -l libraries --scripts/qbe-cc (link)--> prog
```

`scripts/mrustc-nfcc.sh prog.rs -o prog` runs all of it. `scripts/setup-mrustc.sh` builds mrustc and the 1.90 standard
library into `build/mrustc/src` (pinned commit `d85e86b`, from the mrustc `build-1.90.0.sh` steps). The driver takes
`MRUSTC` and `MRUSTC_STD` to use another build. The edition defaults to 2021.

## 2. What mrustc's C needed (`scripts/mrustc-prep.rb`, and one fix in `qbe-prep.rb`)

Measured on `hello.rs` and the `Vec` program. cproc stops at the first error, so each form was found by rerunning.

| Form in mrustc's C | Where | Fix |
| --- | --- | --- |
| `_Atomic` qualifier | `<stdatomic.h>` typedefs | dropped, as `scripts/strip-atomic.py` does for libc++ |
| `__mrustc_atomicloop{8,16,32,64}`: generic `__atomic_load`/`__atomic_compare_exchange` in statement expressions | the prelude (one line each) | the same loop over the sized `__atomic_load_N` / `__atomic_compare_exchange_N`, which qbe-prep.rb declares and libatomic provides |
| `extern T ZRG…(…)` then `asm("__rust_alloc");` (the symbol name is an asm label) | the `alloc` and `panic_impl` externs | the label leaves the C; the tail defines the mangled name as `jmp LABEL@PLT` |
| `$` in identifiers (mangled closure names such as `…27c$75df2d54c9d48882`) | the program's own functions | `qbe-prep.rb` split identifiers at `$` (its `WORD_B` continuation class has no `$`), which made its bare-`return;` rewrite take the wrong return type. Fixed in `qbe-prep.rb` and in the Python oracle `tests/mruby/oracle/qbe-prep.py`; the port check (`tests/mruby/qbe-prep.sh`) still agrees on all 92 edge-case outputs |

Rewrites that were tempting but wrong:

- Renaming the mangled identifiers to their asm labels in C. The label `__rust_alloc` is also defined in the same file
  with a different pointer signedness, so the renamed declaration conflicts with it.
- Dropping `$` from the names. A name may be external, and the gcc-built std objects must link against the same
  spelling.

The assembly tail is ELF only (no leading underscore on symbols; `.type` and `@PLT`). The driver therefore works on Linux.

## 3. Checks

- `tests/mrustc/run.sh`: `hello` prints `Hello, world!`; `vec_sum` prints `55 10`. Needs `scripts/setup-mrustc.sh`.
- The program runs from another directory with relative paths (the driver resolves them before it changes directory).
- `MRUSTC_NFCC_KEEP=1` keeps the intermediate files of a run, for debugging.

## 4. What is not done, and what the numbers say

- **The standard library is gcc-built.** mrustc's build of Rust 1.90.0 is 42 crates and about 1.5 million lines of C
  (`output-1.90.0/*.rlib.c`; libcore alone is 591 thousand). The driver links those objects as they are. That is a
  hybrid, so nothing in `std` is covered by nfcxx's checks.
- **Not tried yet:** compiling the standard library's C through `qbe-cc`. `libcore` would be the first test. It will need
  more rewrites than the program did (glibc and the std prelude use `long double` and `__int128` helpers, which cproc
  rejects; see `docs/notes/pathb-longdouble.md` and `pathb-int128.md` for how the other pipeline handles them).
- **Not exercised:** panics (mrustc's panic path is setjmp/longjmp through `mrustc_panic_target`), inline asm,
  checked arithmetic (`__builtin_*_overflow`, which qbe-prep.rb rewrites, not exercised here), trait objects,
  threads and atomics at run time.
- **Borrow checking:** none. mrustc assumes its input is valid (`docs/notes/borrowck-plan.md` §4.4). A program that
  rustc would reject is compiled.
- **Port check:** `tests/mruby/qbe-prep.sh` needs EDG for its corpus part, which was skipped here. Its edge-case part
  passed (92 of 92 identical). Its vacuity check then fails, because the corpus that produces the atomic rewrites is
  missing. That failure is not caused by the `$` change.
- mrustc also links its own gcc binary of each program during the run, and the driver discards it.

## 5. Next steps

1. Compile `libcore` from mrustc's output through `qbe-cc`, count the cproc errors, and fix them the same way as above.
2. Link the program against the nfcxx-compiled `std` instead of mrustc's objects.
3. Add a program that panics and one that uses a trait object, a closure and `checked_add`, as runtime tests.
