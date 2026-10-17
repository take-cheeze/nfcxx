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

- `tests/mrustc/run.sh` (fifteen cases, about 40 seconds once the crates are cached; the first run of `vec_sum_all`
  builds all of them, a few minutes). It runs in CI as the `mrustc` job, which is part of `build-and-test`:
  - `hello` prints `Hello, world!`; `vec_sum` prints `55 10`; `vec_sum_core` (`MRUSTC_NFCC_CORE=1`) and `vec_sum_all`
    (`MRUSTC_NFCC_CRATES=all`) print the same;
  - on the all-crates build: `threads` (atomics, `Mutex`, `join`), `fsio` (`File`, `metadata`, `remove_file`), `proc`
    (a child process through `Command`), `hashing` (`HashMap`, the random state), `floats` (formatting), and `i128`
    (128-bit arithmetic);
  - also on the all-crates build: `time` (`Instant`, `SystemTime`, `sleep`, `Duration` formatting), `net` (a TCP echo
    over loopback with a server thread, a UDP datagram, a refused connection), `signals` (a handler installed with
    `signal` and raised with `raise`), `dlopen` (`dlopen`, `dlsym`, `dlclose`, `dlerror` on libc and libm), and
    `checked` (checked, overflowing, wrapping and saturating arithmetic at several widths).
  Each expected output was also produced by mrustc's gcc-built standard library, and checked against Rust's semantics.
  Two results mrustc gets wrong are left out (section 4).

  Needs `scripts/setup-mrustc.sh`.
- Also checked by hand, on the gcc-std build and the all-crates build alike: `std::env::args` sees its arguments (the
  `.init_array` rewrite); stdin is read line by line; `is_x86_feature_detected!` reports `sse2` and `avx2` on this host;
  a panic prints its message and aborts with 134 (mrustc's `panic_abort` default); with `-C panic=unwind`,
  `catch_unwind` catches an explicit panic.
- Not buildable: `AtomicU128`. mrustc reports an unresolved `use` for it, which suggests the type is cfg-gated on a
  target property mrustc does not set (not verified). So the 16-byte atomic helpers are compiled, but no program that
  mrustc builds here reaches them.
- The program runs from another directory with relative paths (the driver resolves them before it changes directory).
- `MRUSTC_NFCC_KEEP=1` keeps the intermediate files of a run, for debugging.
- Real crates with dependencies: `tests/realworld/run_mrustc.sh` runs each case under `tests/realworld/mrustc/`. The
  dependency tree is built by mrustc's `minicargo` from a `cargo vendor` of the case's lock file, then the program and
  every crate of its link are compiled by the pipeline (`MRUSTC_NFCC_CRATES=all`), and the output is compared with
  rustc's. Two cases so far:
  - `serde-json`: serde_json 1.0.133 with serde, serde_core, ryu, itoa and memchr (and their build scripts);
  - `regex`: regex 1.13.1 with regex-automata, regex-syntax, aho-corasick and memchr. Its largest crate, regex-automata,
    has a 40 MB C file. It needed the QBE change below.
  Each takes a few minutes cold (`cargo vendor` and the mrustc build of the tree, then the pipeline) and needs network
  access for `cargo vendor`.
- **QBE's parallel moves.** `rega.c` holds at most 64 copies in one parallel move, the copies a block edge needs for
  phi operands and call arguments. A join with more stopped QBE with `no more pm slots` while building regex-automata.
  `scripts/setup-qbe.sh` now raises the limit to 1024 in the build copy (a static array, so no cost). The change
  belongs in the QBE fork as a commit; the pin in `3rd/qbe` is unchanged.
- libcore's object, built through nfcxx, has 19,796 defined symbols; mrustc's gcc-built `libcore.rlib.o` has 19,476.
  The counts are not expected to match exactly; they are a sanity check, not a proof.

## 4. What is not done, and what the numbers say

- **The system is still gcc's.** The objects are nfcxx's, but the linker driver (`cc`), the assembler (`as`, which
  QBE's output goes through) and glibc, libgcc_s, libm and the rest come from the host.
- **Not exercised:** panics that unwind through more than one frame of user code, `std::fs` beyond the `fsio` case,
  the `libtest` and `proc_macro` crates (section 4 below), and the 16-byte atomics (no program reaches them). `time`,
  networking, signals, `dlopen` and checked arithmetic are now covered (section 3).
- **mrustc's bugs found by the checked-arithmetic and time cases.** Both reproduce in mrustc's own gcc build, so they
  are not the pipeline's, and both are left out of `checked.rs`:
  - The 128-bit multiply helper in mrustc's prelude (`mul128_o`) does not flag the bits of the multiplicand it shifts
    out, so `(1u128 << 100).checked_mul(1 << 28)` gives `Some(0)`, not `None`.
  - mrustc's constant evaluator folds `(-30000i16).checked_mul(2)` to `Some(5536)` (the wrapped value, not overflowing).
    At run time the same operation gives `None`. `checked.rs` passes its operands through a non-`const` function so
    they are not folded.
- **The `0xffffffffdeaddead` warnings.** Assembling some crates warns `0xffffffffdeaddead shortened to 0xad`. The
  constant is QBE's undefined-value marker (section 6). It is not proven harmless, but no output changed when the marker
  was changed (section 6).
- **mrustc's own bugs, not the pipeline's:** `let _ = v[3];` and `v[10]` inside a closure do not panic on an empty or
  short `Vec`, in mrustc's gcc build as well. Panics report `:0:0` locations, since mrustc does not track source
  positions.
- **Borrow checking:** none. mrustc assumes its input is valid (`docs/notes/borrowck-plan.md` §4.4). A program that
  rustc would reject is compiled.
- **Port check:** `tests/mruby/qbe-prep.sh` needs EDG for its corpus part, which was skipped here. Its edge-case part
  passed (92 of 92 identical). Its vacuity check then fails, because the corpus that produces the atomic rewrites is
  missing. That failure is not caused by the `$` change.
- **mrustc cannot compile `zmij` 1.0.23** (the float formatter of serde_json 1.0.154): it aborts with `Mismatched types -
  f64 and f32` (`src/hir/hir_ops.cpp:133`). The serde test pins serde_json 1.0.133, which uses `ryu`. This is a
  frontend bug to report upstream or fix in a fork, not a pipeline problem.
- **Only the crates the program links are built.** `libtest`, `proc_macro` and the other crates of the 1.90 build were
  surveyed through the rewrite and cproc and accepted, but not compiled and linked.
- mrustc also links its own gcc binary of each program during the run, and the driver discards it.

## 5. Next steps

1. Panics that unwind through several frames, `std::fs` beyond `fsio`, and `libtest`/`proc_macro` (compile and link).
2. The undefined-value site that does run (section 6): either make mrustc's C initialise the return union, or accept
   the copy as dead by construction. Other sites are not reached by any program in the suite.
3. Decide whether the rewrites belong in a fork of mrustc's codegen rather than in text. They are specific to this pin
   of mrustc, and each new pin means redoing the census (section 2). The two mrustc bugs in section 4 would be fixed
   there, not in text.
4. CI: the `mrustc` job (`.github/workflows/ci.yml`) caches mrustc's compiler and standard library (`bin/mrustc`,
   `output-1.90.0`) and the per-crate objects. It has not run on GitHub's runners yet: the first run is the test of the
   cold build (minutes; a download of the rustc source).

## 6. Undefined values: what was checked

QBE's SSA renaming returns its undefined value where a temporary has no reaching definition (`getstk` in
`3rd/qbe/ssa.c`), and slot coalescing turns a load from a slot that is never stored into a copy of it (`3rd/qbe/mem.c`).
The undefined value is `UNDEF`, the constant `0xdeaddead` (`parse.c`). Those are the sites the assembler reports.

- **Where the reads are.** A scratch copy of QBE, not the repo's, prints each site: the phi operands at a join
  (`ssa.c`) and the never-stored slot loads (`mem.c`). A positive control (a function that reads an uninitialised
  local on one path) is reported, so the instrumentation works. Counts for libcore: 97 phi operands in 50 functions,
  and 30 slot loads. For alloc: 4 and 6. For std: 15 and 14. Instrumenting the ordinary instruction operands (the other
  place renaming can put the undefined value) reported none in the three crates.
- **Whether they matter.** The undefined value is QBE's constant for an uninitialised read. The question is whether
  the program ever depends on it. A scratch copy of QBE with the constant set to `0` and another with `0x5a5a5a5a` were
  each used to rebuild all the crates and the twelve runtime programs (the runtime cases, `vec`, `args`, `stdin`,
  `unwind`, `boom`). All twelve gave identical output under the three values. That is evidence that these programs do not
  depend on those reads. It is not proof for every site.
- **Why there are reads at all.** mrustc's C declares a function's locals up front and assigns them on the paths of the
  MIR that define them, so a join can see a variable that was assigned on one path only. In valid Rust such a value is
  only read where the MIR defines it. Whether any site is reachable and used is what section 5 item 2 would settle.
- **Which sites run.** A probe build (scratch: a QBE copy with a call to `__nfcxx_undef_probe(id)` at the start of each
  block that reads `UNDEF` in an instruction or a jump, or feeds it to a successor's phi; the map from ids to function
  and block is written at compile time). Block entry over-approximates, so a probe that never fires proves that no
  such read ran. A positive control (an uninitialised local read on one path) fires and prints the value
  `-559030611`, which is `0xdeaddead`. Across the fifteen programs of section 3, all built with `MRUSTC_NFCC_CRATES=all`,
  exactly one site runs: `std::sys::net::connection::socket::socket_addr_to_c`, in its IPv4 arm, which the `net` case
  calls six times (one per IPv4 address conversion). The other fourteen programs never reach a probe.
- **What the reached site does.** Its join phi takes `UNDEF` from the IPv4 edge for three words, and stores them into
  bytes 16 to 28 of the `SocketAddrCRepr` union that the function returns. The IPv4 arm writes only the first 16 bytes
  (`sockaddr_in`), and returns length 0x10, so `bind`, `connect` and `sendto` read only those bytes. The copied
  `UNDEF` bytes are never read by a consumer, so the program's output does not depend on them. This is dead by
  construction for this site, not a general argument: the same shape in another function would need its own check.
  The root is mrustc's C, which leaves the union's unused tail unwritten; a fix would zero it in mrustc's output.
