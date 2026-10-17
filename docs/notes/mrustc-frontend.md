# Rust programs through mrustc and nfcxx's C pipeline

Status: **Rust programs run, and libcore runs through nfcxx too.** `tests/mrustc/run.sh` builds `hello.rs` and a
`Vec`/iterator/`format!` program, and both print the expected output. The program's own C, and the monomorphised
generics it uses, are compiled by nfcxx's C pipeline (cproc → QBE). `MRUSTC_NFCC_CORE=1` also compiles `libcore`
(the largest crate, 591 thousand lines of mrustc C) through the same pipeline; the `Vec` program links against that
object and still prints `55 10`. The rest of the standard library (`alloc`, `std`, `test`, ...) is still mrustc's,
built with gcc, and is linked in as objects.

The C backend is the fastest route to a running program: it already compiles the full Rust 1.90.0 standard library.
The other output, mrustc's monomorphised MIR (`-C codegen-type=monomir`), would need a new translator to nfcxx's IR
and is not started.

## 1. Pipeline

```
prog.rs --mrustc (-o prog)--> prog.c + prog_cmd.txt (mrustc's gcc command: the std objects and libraries)
prog.c --cc -E -P -D__CPROC__ (no -undef)--> pp.c
pp.c --scripts/mrustc-prep.rb--> prep.c, tail.s (helpers, asm-label trampolines), weak.txt (weak data symbols)
prep.c --scripts/qbe-cc -c (cc -E -undef, qbe-prep.rb, cproc, QBE, as)--> prog.o
prog.o --objcopy --weaken-symbols=weak.txt (when weak.txt is not empty)--> prog.o
tail.s --cc -c--> prog.tail.o
prog.o prog.tail.o [libcore.o libcore.tail.o] + std objects (prog_cmd.txt) + -l libraries --scripts/qbe-cc (link)--> prog
```

`scripts/mrustc-nfcc.sh prog.rs -o prog` runs all of it. `MRUSTC_NFCC_CORE=1` adds libcore, which is cached in
`build/mrustc/nfcxx/` and rebuilt when its C or the rewrite scripts change. `scripts/setup-mrustc.sh` builds mrustc and
the 1.90 standard library into `build/mrustc/src` (pinned commit `d85e86b`, from the mrustc `build-1.90.0.sh` steps).
The driver takes `MRUSTC` and `MRUSTC_STD` to use another build. The edition defaults to 2021.

Two choices in the first step matter:

- **No `-undef`.** With `-undef`, glibc's `cdefs.h` defines `__attribute__` as empty (it checks `__GNUC__`), so the
  program's `aligned`, `packed` and `weak` attributes vanished: 527 `__aligned__` attributes in libcore's source,
  2 left after preprocessing with -undef. The rewrites below depend on the attributes, so the first stage keeps the host's GNU macros.
  `qbe-cc` still preprocesses its input with `-undef`, but by then the file has no headers left to undefine anything.
- **Weak data is weakened in the object.** mrustc marks its vtables and type ids weak (`__attribute__((weak))`), and
  cproc ignores the attribute on data. A `.weak` directive in another object does not reach the definition, so
  `objcopy --weaken-symbols` edits the object that defines the symbol.

## 2. What mrustc's C needed

Measured on `hello.rs`, the `Vec` program, and libcore. cproc stops at its first error, so the list was found by
rerunning, and a census of each construct then sized what was left.

| Form in mrustc's C | Count (libcore) | Fix (`scripts/mrustc-prep.rb` unless noted) |
| --- | --- | --- |
| `_Atomic` qualifier (`<stdatomic.h>`) | from the typedefs | dropped, as `scripts/strip-atomic.py` does for libc++ |
| `__extension__`, `__restrict`, `__restrict__` | in glibc's headers | dropped / the C99 `restrict`, which cproc reads |
| `__mrustc_atomicloop{8,16,32,64}` (the prelude's fetch-op loop) | 4 lines | the same loop over the sized `__atomic_load_N` / `__atomic_compare_exchange_N`, which `qbe-prep.rb` declares |
| `extern T ZRG…(…)` then `asm("__rust_alloc");` (an asm label naming the symbol) | 6 externs | the label leaves the C; the tail defines the mangled name as `jmp LABEL@PLT` (weak) |
| `#pragma pack(push, 1)` around a struct | 65 regions | cproc ignores `#pragma`; the struct gets `__attribute__((packed))` after its keyword, which is the only place cproc reads it |
| `__attribute__((__aligned__(16),))`, the trailing comma | 8 | dropped on attribute lines (`,)` also occurs in string literals) |
| Placeholders for unimplemented intrinsics: `({ if (!"MSG") ; else __assert_fail (…); })` | 1434 | `(!"MSG" ? (void)0 : __assert_fail (…))`, the same test; `__PRETTY_FUNCTION__` becomes `__func__` |
| Atomic load, store, exchange, compare-exchange in statement expressions (`({ __auto_type … })`) | 425 (315 CAS, 50 exchange, 30 store, 30 load) | an expression over the sized builtin of the pointee's width, with a cast where a value comes back. The 15 on `uint128_t` (a struct) use four helpers after its typedef, over the generic libatomic calls |
| Inline asm: `pause`, `xgetbv`, `cpuid` | 3 | `pause` is a no-op hint and becomes `;`; the other two call helpers in the tail (x86-64, System V) |
| glibc's `strerror_r` redirect, `__asm__ ("" "__xpg_strerror_r")` | 1 | dropped: libcore only declares the function |
| Weak data: `__attribute__((weak)) union {…} NAME;` and `T NAME __attribute__((weak));` | 312 names | the names go to `weak.txt`; `objcopy --weaken-symbols` in `scripts/mrustc-nfcc.sh` |
| `$` in identifiers (mangled names such as `…27c$75df2d54c9d48882`) | many | `qbe-prep.rb`'s scanner split identifiers at `$`; fixed in `qbe-prep.rb` and in the Python oracle `tests/mruby/oracle/qbe-prep.py` (the port check still agrees on all 92 edge-case outputs) |

Rewrites that were tempting but wrong:

- Renaming the mangled identifiers to their asm labels in C. The label `__rust_alloc` is also defined in the same file
  with a different pointer signedness, so the renamed declaration conflicts with it.
- Dropping `$` from the names. A name may be external, and the gcc-built std objects must link against the same
  spelling.
- A `.weak` directive in the tail: it only affects symbols of its own object.

The assembly tail and the helpers are ELF and x86-64 only. The driver therefore works on Linux x86-64.

## 3. Checks

- `tests/mrustc/run.sh`: `hello` prints `Hello, world!`; `vec_sum` prints `55 10`; `vec_sum_core` (with
  `MRUSTC_NFCC_CORE=1`) prints `55 10`. Needs `scripts/setup-mrustc.sh`. The first `vec_sum_core` run also builds the
  libcore object (about half a minute).
- The program runs from another directory with relative paths (the driver resolves them before it changes directory).
- `MRUSTC_NFCC_KEEP=1` keeps the intermediate files of a run, for debugging.
- libcore's object, built through nfcxx, has 19,796 defined symbols; mrustc's gcc-built `libcore.rlib.o` has 19,476.
  The counts are not expected to match exactly; they are a sanity check, not a proof.

## 4. What is not done, and what the numbers say

- **Most of the standard library is still gcc-built.** libcore is done; the others are `alloc` (78 thousand lines of C),
  `std` (442 thousand), `test` (200 thousand), `compiler_builtins` (54 thousand), and the smaller crates. Each needs the
  same pass, and the counts of constructs above are for libcore only: the others may have forms libcore does not.
- **The libcore object carries assembler warnings.** `0xffffffffdeaddead shortened to 0xad` comes from QBE's undefined
  value marker (`curf->con[0].bits.i = 0xdeaddead` in `3rd/qbe/parse.c`): code reads a value nobody defined, and the
  assembler truncates the constant. It is not investigated; it may be harmless (the value is never used by the program) or it may hide a real
  bug.
- **Not exercised at run time:** the `cpuid` and `xgetbv` helpers (libcore's CPU feature detection), the 16-byte atomics
  (`uint128_t`), panics (mrustc's panic path is setjmp/longjmp through `mrustc_panic_target`), inline asm beyond the three
  above, checked arithmetic (`__builtin_*_overflow`, which `qbe-prep.rb` rewrites for some operand types), trait objects,
  threads and atomics. The `Vec` program exercises libcore's formatting and iterators, not these.
- **Borrow checking:** none. mrustc assumes its input is valid (`docs/notes/borrowck-plan.md` §4.4). A program that
  rustc would reject is compiled.
- **Port check:** `tests/mruby/qbe-prep.sh` needs EDG for its corpus part, which was skipped here. Its edge-case part
  passed (92 of 92 identical). Its vacuity check then fails, because the corpus that produces the atomic rewrites is
  missing. That failure is not caused by the `$` change.
- mrustc also links its own gcc binary of each program during the run, and the driver discards it.

## 5. Next steps

1. Compile `alloc` and then `std` the same way (`nfcxx_compile` in `scripts/mrustc-nfcc.sh` already takes any C file;
   the driver needs a list of crates, not one hard-coded), and count the cproc errors for each.
2. Link a program with every crate compiled through nfcxx; then the gcc-built objects are gone.
3. Investigate the `0xdeaddead` warning: find which reads of undefined values reach an instruction that truncates them.
4. Runtime tests for the paths in section 4: a program that panics, one that uses a trait object and a closure, one that
   calls `std::arch` CPU detection, and one that uses `AtomicU128`.
