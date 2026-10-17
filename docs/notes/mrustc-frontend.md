# Rust programs through mrustc and nfcxx's C pipeline

Status: **Rust programs run with every crate they link compiled by nfcxx.** `MRUSTC_NFCC_CRATES=all` compiles each
rlib of mrustc's link command (13 for a program that uses `Vec`, iterators and `format!`: `core`, `alloc`, `std`,
`compiler_builtins`, `libc`, `hashbrown`, `std_detect`, ...) through the same pipeline as the program. The programs
print the expected output, `std::env::args` sees its arguments, and a panic prints its message and aborts as mrustc's
own build does. What is still gcc's is the system (glibc, libgcc, libm, the linker driver and the assembler).

The C backend is the fastest route to a running program: it already compiles the full Rust 1.90.0 standard library.
The other output, mrustc's monomorphised MIR (`-C codegen-type=monomir`), would need a new translator to nfcxx's IR
and is not started.

## 1. Pipeline

```
prog.rs --mrustc (-o prog)--> prog.c + prog_cmd.txt (mrustc's gcc command: the rlib objects and libraries)
prog.c --cc -E -P -D__CPROC__ (no -undef)--> pp.c
pp.c --scripts/mrustc-prep.rb--> prep.c, tail.s (helpers, asm-label trampolines), weak.txt (weak data symbols)
prep.c --scripts/qbe-cc -c (cc -E -undef, qbe-prep.rb, cproc, QBE, as)--> X.o
X.o --objcopy --weaken-symbols=weak.txt (when weak.txt is not empty)--> X.o
tail.s --cc -c--> X.tail.o
the program, and each crate of MRUSTC_NFCC_CRATES (cached as build/mrustc/nfcxx/CRATE.o)
  + the rlib objects of prog_cmd.txt that are not replaced + -l libraries --scripts/qbe-cc (link)--> prog
```

`scripts/mrustc-nfcc.sh prog.rs -o prog` builds the program. `MRUSTC_NFCC_CRATES` names the crates to compile through
nfcxx (`core alloc std`, or `all`); `MRUSTC_NFCC_CORE=1` is `core` alone. A crate is rebuilt when its C file or the
rewrite scripts are newer than its object. `scripts/setup-mrustc.sh` builds mrustc and the 1.90 standard library into
`build/mrustc/src` (pinned commit `d85e86b`, from the mrustc `build-1.90.0.sh` steps). The driver takes `MRUSTC` and
`MRUSTC_STD` to use another build. The edition defaults to 2021.

Three choices in the first step matter:

- **No `-undef`.** With `-undef`, glibc's `cdefs.h` defines `__attribute__` as empty (it checks `__GNUC__`), so the
  program's `aligned`, `packed` and `weak` attributes vanished: 527 `__aligned__` attributes in libcore's source,
  2 left after preprocessing. The rewrites below depend on the attributes, so the first stage keeps the host's GNU
  macros. `qbe-cc` still preprocesses its input with `-undef`, but by then the file has no headers left to undefine
  anything.
- **Weak data is weakened in the object.** mrustc marks its vtables and type ids weak (`__attribute__((weak))`), and
  cproc ignores the attribute on data. A `.weak` directive in another object does not reach the definition, so
  `objcopy --weaken-symbols` edits the object that defines the symbol. The same goes for std's weak references to
  glibc symbols that may be absent (`extern char __attribute__((weak)) NAME[0];`): `objcopy` turns the undefined
  symbol into a weak one, so the link leaves it null when the symbol is absent.
- **Trampolines have weak targets.** An asm-labelled extern is a jump in the tail, to the symbol of the label. A label
  whose symbol is absent (`sysctl`, removed from glibc 2.32) would otherwise break the link, although nothing calls it.

## 2. What mrustc's C needed

Measured on `hello.rs`, the `Vec` program, libcore, and then every other crate. cproc stops at its first error, so the
list was found by rerunning, and a census of each construct sized what was left.

| Form in mrustc's C | Count | Fix (`scripts/mrustc-prep.rb` unless noted) |
| --- | --- | --- |
| `_Atomic` qualifier (`<stdatomic.h>`) | from the typedefs | dropped, as `scripts/strip-atomic.py` does for libc++ |
| `__extension__`, `__restrict`, `__restrict__` | in glibc's headers | dropped / the C99 `restrict`, which cproc reads |
| `__mrustc_atomicloop{8,16,32,64}` (the prelude's fetch-op loop) | 4 lines | the same loop over the sized `__atomic_load_N` / `__atomic_compare_exchange_N`, which `qbe-prep.rb` declares |
| `extern T ZRG…(…)` then `asm("__rust_alloc");` (an asm label naming the symbol) | a few per crate | the label leaves the C; the tail defines the mangled name as `jmp LABEL@PLT` (weak) |
| `extern T NAME asm("environ");` (a data object with a label, on one line) | 1 (std) | the name is replaced by the label throughout the file; the label leaves the declaration |
| `#pragma pack(push, 1)` around a struct | 65 regions (libcore) | cproc ignores `#pragma`; the struct gets `__attribute__((packed))` after its keyword, which is the only place cproc reads it |
| `__attribute__((__aligned__(16),))`, the trailing comma | 8 | dropped on attribute lines (`,)` also occurs in string literals) |
| `__attribute__((section(".init_array.N")))` on a data object (std's argv capture) | 1 | the attribute leaves the declaration; the tail places `.quad FUNC` in `.init_array.N` (`FUNC` from the initialiser) |
| Placeholders for unimplemented intrinsics: `({ if (!"MSG") ; else __assert_fail (…); })` | 1434 (libcore) | `(!"MSG" ? (void)0 : __assert_fail (…))`, the same test; `__PRETTY_FUNCTION__` becomes `__func__` |
| Atomic load, store, exchange, compare-exchange in statement expressions (`({ __auto_type … })`) | 425 (libcore: 315 CAS, 50 exchange, 30 store, 30 load) | an expression over the sized builtin of the pointee's width, with a cast where a value comes back. Pointers are 8 bytes and their values go through `(unsigned long)`. The 15 on `uint128_t` (a struct) use four helpers after its typedef, over the generic libatomic calls |
| Inline asm: `pause`, `xgetbv`, `cpuid` | 3 forms | matched by their text with the operand names kept (they differ per crate, e.g. `var401`); `pause` is a no-op hint and becomes `;`; the other two call helpers in the tail (x86-64, System V) |
| glibc's `strerror_r` redirect, `__asm__ ("" "__xpg_strerror_r")` | 1 | dropped: libcore only declares the function |
| Weak data: `__attribute__((weak)) union {…} NAME;` and `T NAME __attribute__((weak));` | 312 names (libcore) | the names go to `weak.txt`; `objcopy --weaken-symbols` in `scripts/mrustc-nfcc.sh` |
| Weak references: `extern char __attribute__((weak)) NAME[0];` | 2 (std) | the same, on an undefined symbol |
| `$` in identifiers (mangled names such as `…27c$75df2d54c9d48882`) | many | `qbe-prep.rb`'s scanner split identifiers at `$`; fixed in `qbe-prep.rb` and in the Python oracle `tests/mruby/oracle/qbe-prep.py` (the port check still agrees on all 92 edge-case outputs) |

Rewrites that were tempting but wrong:

- Renaming the mangled identifiers to their asm labels for functions. The label `__rust_alloc` is also defined in the
  same file with a different pointer signedness, so the renamed declaration conflicts with it. (Data objects are
  renamed, since they have no such conflict.)
- Dropping `$` from the names. A name may be external, and the gcc-built objects must link against the same spelling.
- A `.weak` directive in the tail: it only affects symbols of its own object.

The assembly tail and the helpers are ELF and x86-64 only. The driver therefore works on Linux x86-64.

## 3. Checks

- `tests/mrustc/run.sh` (four cases, about ten seconds once the crates are cached; the first run of `vec_sum_all`
  builds all of them, a few minutes):
  - `hello` prints `Hello, world!`;
  - `vec_sum` prints `55 10`;
  - `vec_sum_core` (`MRUSTC_NFCC_CORE=1`) prints `55 10`;
  - `vec_sum_all` (`MRUSTC_NFCC_CRATES=all`) prints `55 10`.
  Needs `scripts/setup-mrustc.sh`.
- Also checked by hand: a program that prints its arguments (`std::env::args`, through the `.init_array` rewrite) gives
  `3 x` for `x y`, in both the gcc-std build and the all-crates build. A program that panics prints the panic message
  and aborts with 134, in all of: mrustc's own build, the gcc-std build and the all-crates build.
- The program runs from another directory with relative paths (the driver resolves them before it changes directory).
- `MRUSTC_NFCC_KEEP=1` keeps the intermediate files of a run, for debugging.
- libcore's object, built through nfcxx, has 19,796 defined symbols; mrustc's gcc-built `libcore.rlib.o` has 19,476.
  The counts are not expected to match exactly; they are a sanity check, not a proof.

## 4. What is not done, and what the numbers say

- **The system is still gcc's.** The objects are nfcxx's, but the linker driver (`cc`), the assembler (`as`, which
  QBE's output goes through) and glibc, libgcc_s, libm and the rest come from the host.
- **Not exercised at run time:** the `cpuid` and `xgetbv` helpers beyond what the programs above reach (std's feature
  detection is linked, but its use in these programs is not known), the 16-byte atomics (`uint128_t`), threads and
  atomics, trait objects, `std::fs`, processes, checked arithmetic (`__builtin_*_overflow`, which `qbe-prep.rb` rewrites
  for some operand types). The `Vec` and `args` programs exercise formatting, iterators, the allocator and argv.
- **The `0xffffffffdeaddead` warnings.** Assembling some crates warns `0xffffffffdeaddead shortened to 0xad`. The
  constant is QBE's undefined-value marker (`curf->con[0].bits.i = 0xdeaddead` in `3rd/qbe/parse.c`): code reads a
  value nobody defined, and the assembler truncates the constant. Not investigated; it may be harmless (the value is
  never used by the program) or it may hide a real bug. The count per crate was not recorded.
- **mrustc's own bugs, not the pipeline's:** `let _ = v[3];` on an empty `Vec` does not panic, in mrustc's gcc build as
  well. Panics report `:0:0` locations, since mrustc does not track source positions.
- **Borrow checking:** none. mrustc assumes its input is valid (`docs/notes/borrowck-plan.md` §4.4). A program that
  rustc would reject is compiled.
- **Port check:** `tests/mruby/qbe-prep.sh` needs EDG for its corpus part, which was skipped here. Its edge-case part
  passed (92 of 92 identical). Its vacuity check then fails, because the corpus that produces the atomic rewrites is
  missing. That failure is not caused by the `$` change.
- **Only the crates the program links are built.** `libtest`, `proc_macro` and the other crates of the 1.90 build were
  surveyed through the rewrite and cproc and accepted, but not compiled and linked.
- mrustc also links its own gcc binary of each program during the run, and the driver discards it.

## 5. Next steps

1. Run a wider runtime check on the all-crates build: threads, atomics, `std::fs`, processes, panics that unwind through
   user code, and `is_x86_feature_detected!`. Each finds a rewrite that is wrong only at run time, if there is one.
2. Investigate the `0xdeaddead` warnings: find which reads of undefined values reach an instruction that truncates them.
3. Decide whether the rewrites belong in a fork of mrustc's codegen rather than in text. They are specific to this pin
   of mrustc, and each new pin means redoing the census (section 2).
4. Wire the all-crates test into CI, with a cache for `build/mrustc`. The first build takes minutes.
