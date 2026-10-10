# nfcxx documentation

`docs/DESIGN.md` is the design and the original plan. `docs/notes/` holds one note per piece of work. Notes are
written as work happened, so a later round can supersede an earlier statement inside a note; this page is the
current-state summary, and every claim in it names the test script that covers it. Claims that no script
covers say so.

## Index of `docs/notes/`

| Note | One line |
| --- | --- |
| [build-self-hosting.md](notes/build-self-hosting.md) | What the build fetches, which host tools it needs for which step, and how to build offline from mirrored submodules. |
| [builtins.md](notes/builtins.md) | Table of compiler builtins: what EDG accepts per dialect and what runs on the gcc and qbe backends. |
| [eval.md](notes/eval.md) | `nfceval` (`lib/eval`): evaluating C++ snippets at run time with bound host objects, and `nfcxx -shared`. |
| [eh-shim.md](notes/eh-shim.md) | Exceptions thrown by libstdc++.so (`std::__throw_*`) and `std::exception_ptr` on EDG's exception runtime: the shim library, the runtime hooks, link order, limits. |
| [freestanding.md](notes/freestanding.md) | The `lib/` headers, `nfcxx --freestanding`, and the cproc limits met while writing them. |
| [hexagon.md](notes/hexagon.md) | Generated C through clang for Hexagon, run on qemu-hexagon; what blocks a real Hexagon target. |
| [mruby-scripting.md](notes/mruby-scripting.md) | The build's helper scripts run on a self-built mruby instead of Python; how each port is verified byte for byte. |
| [pathb-longdouble.md](notes/pathb-longdouble.md) | Path B `long double`: 16-byte objects, helper calls compiled by gcc, x87 thunks for the C calling convention; tests and named limits. |
| [pathb-stage1.md](notes/pathb-stage1.md) | Path B harness: a `cpfe` with our own back end that dumps EDG's lowered IL (historical; harness still used). |
| [pathb-stage2.md](notes/pathb-stage2.md) | The mid-level IR: structured control flow, typed three-address form, explicit checks; spec and coverage. |
| [pathb-stage3.md](notes/pathb-stage3.md) | The IR-to-QBE emitter, translation validation, and the rounds of closed gaps (volatile, TLS, exceptions, dynamic init, bit-fields, VLAs). |
| [realworld.md](notes/realworld.md) | tinyxml2, doctest, Lua, mruby built with nfcxx/nfcc, what each needed, `nfcc` options. |
| [tracing.md](notes/tracing.md) | `--trace` Chrome/Perfetto JSON of the driver steps. |

## Status matrix

"Test" is the script that exercises the claim. "CI" is the workflow that runs it (`ci.yml`, `pathb.yml`,
`realworld.yml`, `hexagon.yml`); "none" means no workflow runs it. A test marked "needs X" skips or fails without X.

| Area | Supported (test) | CI |
| --- | --- | --- |
| Path A, gcc backend (`nfcxx --backend=gcc`: EDG's C through `gcc -O2 -fwrapv -fno-strict-aliasing`) | The 15 programs of `tests/cases` (`NFCXX_BACKEND=gcc tests/run.sh`); freestanding library (`tests/lib/run.sh`); builtin probes (`tests/builtins/run.sh`); C inputs (`tests/c/run.sh`); tinyxml2 (`tests/realworld/run.sh`); doctest on the hosted headers (`tests/realworld/run_doctest.sh`, gcc only) | ci.yml, realworld.yml |
| Path A, qbe backend (the default: EDG's C -> `qbe-prep.rb` -> cproc -> QBE -> asm; `scripts/qbe-cc`) | Same `tests/cases`, `tests/lib`, `tests/builtins`, `tests/c`, tinyxml2 as above with `NFCXX_BACKEND=qbe` or the default; C++ exceptions (`tests/cases/exceptions.cpp`); signed overflow wraps (`tests/cases/signed_overflow_wraps.cpp`); Lua and mruby as C (`run_lua.sh`, `run_mruby.sh`) | ci.yml, realworld.yml |
| Path B (EDG lowered IL -> own IR -> QBE, `scripts/setup-pathb.sh`, `be/`, `scripts/pathb-qbe-emit.rb`) | IL goldens (`tests/pathb/run.sh`); IR goldens and node coverage (`tests/pathb-ir/run.sh`); IR -> QBE -> run, equal to `// EXPECT:` and to the gcc backend (`tests/pathb-qbe/run.sh`): arithmetic and control flow, `continue`, bool loads, `setjmp`, bit-fields (`cases/bitfield*.cpp`), VLAs including scope exit (`cases/vla*.cpp`), GNU statement expressions (`cases/stmtexpr*.cpp`), volatile (`cases/volatile.cpp`), thread-local objects (`cases/tls*.cpp`, `multi/tls_*`), dynamic initialization (`cases/dyn_*.cpp`, `multi/dyn_init`), C++ exceptions (`cases/eh_*.cpp`), `long double` (`cases/longdouble_*.cpp`, `multi/abi_ld`, `traps/longdouble_*`; `docs/notes/pathb-longdouble.md`), COMDAT/weak linkage (`multi/comdat`, `multi/weak_link`), checked operations that must abort with SIGABRT (`traps/`) | pathb.yml |
| Path B, hosted (`NFCXX_PATH=b ./nfcxx`, `scripts/pathb-cc`, `scripts/host-sys.sh`; `docs/notes/pathb-hosted.md`) | Programs using the host C and C++ headers and libstdc++: hosted probes `tests/pathb-qbe/cases/{hosted_*,abi_struct,vararg_def,base_null}.cpp` and `multi/abi_c`, `tests/cases` through the driver (`NFCXX_PATH=b tests/run.sh`), tinyxml2 (exit 12); all in `tests/pathb-qbe/hosted.sh`. doctest builds and exits 2 as expected (no CI script; `pathb-hosted.md`, "long double"). Several translation units sharing libstdc++ templates: `tests/multi-tu/run.sh` (`docs/notes/multi-tu.md`, both backends) | pathb.yml (hosted.sh), ci.yml (multi-tu) |
| EH shim (`lib/ehshim`, `scripts/ehshim`; `docs/notes/eh-shim.md`) | Exceptions thrown inside libstdc++ (`vector::at`, `std::stoi`, empty `std::function`, `string::_M_create`, `thread::join`, `promise`/`future`, `regex`) are caught by EDG-compiled handlers; `std::current_exception`, `exception_ptr`, `rethrow_exception`, `make_exception_ptr`, `throw_with_nested`; `new` failure on the gcc backend. Path A both backends, Path B: `tests/cases/eh_libstdcxx_throw.cpp`, `tests/cases/eh_exception_ptr.cpp` (all `tests/run.sh` modes and `tests/pathb-qbe/run.sh`), `tests/pathb-qbe/cases/hosted_eh_system.cpp`, and `tests/ehshim/run.sh` (output compared with host g++). `exception_ptr` needs the hooks of the patched `libC.a` (submodule `3rd/edg`); without them the test reports SKIP | ci.yml, pathb.yml |
| Hexagon | Generated C for the `linux_riscv32` stand-in target compiles with clang-19 `--target=hexagon` and runs under qemu-hexagon, HVX kernels included; struct layout equals clang's Hexagon ABI (`tests/hexagon/run.sh`, `tests/hexagon/layout.sh`). Not the Hexagon SDK, QuRT or `hexagon-sim` (unavailable, `docs/notes/hexagon.md` section 4). | hexagon.yml |
| `nfcc` (drop-in `cc`, C only) | `-c`, link, `-S`, `-E`/`-M*` answered by the host compiler, `-D -U -I`, dependency files, response files, `-shared`, rejected options, on both backends (`tests/c/cc-mode.sh`); Lua through its own makefile (`tests/realworld/run_lua_make.sh`); mruby's rake build (`tests/realworld/run_mruby.sh`) | ci.yml, realworld.yml |
| `nfceval` (`lib/eval`) and `nfcxx -shared` | Evaluate snippets with bound objects/functions/methods, errors as exceptions, cache, shared objects, on both backends (`tests/eval/run.sh`) | ci.yml |
| Tracing (`--trace=FILE`, `NFCXX_TRACE`) | Valid trace-event JSON with the driver and backend spans, both backends, exit code unchanged (`tests/trace/run.sh`, needs python3) | ci.yml |
| mruby scripting (`scripts/mrb`, `*.rb`) | Every ported script gives output byte-identical to its Python original (`tests/mruby/run.sh`; Path B and Hexagon parts need the harness and a clang with the Hexagon target, else they skip) | ci.yml (Path A parts), pathb.yml (with the harness) |

Every `tests/*/run.sh` and `tests/realworld/*.sh` is wired into a workflow, with these exceptions:
`tests/builtins/fe_matrix.sh` prints a table (EDG acceptance of each builtin in three dialects) and has no pass/fail,
and `tests/mruby/qbe-prep.sh` and `qbe-prep-tap.sh` are run by `tests/mruby/run.sh`. `tests/realworld/*.sh` clone
upstream sources at pinned commits and report SKIP (exit 0) when the fetch fails, so an unreachable GitHub shows up as a
SKIP line in the log, not as a red job.

## Known limitations, in one place

Each entry names where it comes from and what, if anything, checks it.

**`long double`**
- Path A qbe: cproc rejects it ("long double is not yet supported"). `tests/realworld/run_doctest.sh` therefore
  runs doctest on gcc only and reports a SKIP for qbe (`docs/notes/realworld.md`).
- Path B: supported (`docs/notes/pathb-longdouble.md`). A `long double` is a 16-byte object in the x86-64 layout, every operation is a
  call of a helper in `be/nfcxx_ldrt.c` (gcc, x87), results in `st(0)` go through generated assembly thunks, so libc, libm
  and libstdc++.so are called directly. Checked by `tests/pathb-qbe/cases/longdouble_*.cpp`, `multi/abi_ld`, the traps
  `traps/longdouble_*.cpp` (all in `tests/pathb-qbe/run.sh`), the IR golden `tests/pathb-ir/longdouble_ir.ir` and the thunk
  edge cases `tests/mruby/pathb-edge/x87_thunks.ir` (`tests/mruby/run.sh`, Python oracle identical). Named limits: function
  pointers to `long double` functions use the internal convention, structs of at most 16 bytes holding one by value,
  `_Float128`, `std::format` (blocked by `_Float128`); see the note, section 7. The option
  `--long-double=trap` remains for hand-written IR that still mentions the scalar type
  (`tests/mruby/pathb-edge/r_longdouble.ir`).
- Hexagon: EDG's `long double` is 16 bytes, Hexagon's is 8; `tests/hexagon/layout.sh` leaves it out (`hexagon.md`).

**`_Complex`**: unsupported by cproc ("_Complex is not yet supported"), so by Path A qbe and by `nfcc` on qbe
(`realworld.md`, "What remains"; the mruby gem `mruby-cmath` is the case). No test asserts it; checked by hand with a
one-line `.c` file (qbe fails, gcc backend runs it). Path B has no `_Complex` handling (`ck_complex` is listed as not covered in `pathb-stage1.md`).

**Exceptions**
- EDG lowers C++ exceptions to its own setjmp/longjmp ABI and runtime (`libC.a`). Such a program runs on Path A
  (`tests/cases/exceptions.cpp`) and Path B (`tests/pathb-qbe/cases/eh_*.cpp`), with no zero-cost unwinding: every
  function with a handler keeps all its slots in memory (`pathb-stage3.md`, "C++ exceptions", Limits).
- Exceptions thrown by libstdc++ through its `std::__throw_*` functions (`std::string::at`, `vector::at`, `std::stoi`, empty
  `std::function`, ...) and `std::exception_ptr` work: the driver links `lib/ehshim`, a shim that throws them with EDG's runtime
  (`eh-shim.md`; `tests/cases/eh_libstdcxx_throw.cpp`, `tests/cases/eh_exception_ptr.cpp`, `tests/ehshim/run.sh`). What is left: libstdc++
  code that throws without a `__throw_*` function (plain `__cxa_throw`) still aborts, EDG's `longjmp` skips the destructors of
  libstdc++'s own frames, the EH runtime is not thread safe (`eh-shim.md`, "Limits").
- An exception cannot unwind across a shared-object boundary (each object has its own EH stack): `nfceval` catches inside
  the snippet and rethrows a `RuntimeError` in the host (`tests/eval/run.sh`).
- Hexagon EH runtime: multiple/virtual-base catch matching, `noexcept` violations, array `new` unwinding and thrown
  `double`/`float` are not supported (`hexagon.md`, section 3a). No test asserts the failures.
- Path B and Path A alike catch exceptions thrown inside libstdc++.so through the shim above (`vector::at`, `std::__throw_*`). Before
  it they aborted (the gcc unwinder); `new` of a huge size on the gcc backend too (libstdc++'s `operator new`; the driver now links `libC.a`
  first). User-code throws and `std::runtime_error` constructed in user code work (`tests/pathb-qbe/cases/hosted_stdexcept.cpp`, `eh_std.cpp`).

**Variable-length arrays (Path B)**: storage is EDG's `__vla_alloc`/`__vla_dealloc` pool in `libC.a`, a single global that
is not thread safe, costing two calls and a `malloc` per VLA; subscripts of the VLA variable are bounds-checked (abort)
against the run-time count, except through a run-time inner dimension or a pointer (`pathb-stage2.md` 5b, `pathb-hosted.md`;
`tests/pathb-qbe/cases/vla_bounds.cpp`, `traps/vla_index.cpp`). Scope exit is checked single-threaded by `tests/pathb-qbe/cases/vla_scope.cpp`.


**Inline asm**: Path A qbe handles only `__asm__ volatile("int $3")` (`tests/cases/qbe_int3_break.cpp`); Path B accepts empty
barriers, nops/`pause`, fences (`mfence`, `lfence`, `sfence`, `lock; addl`), `ud2`, `int $3`, `rdtsc` with `"=a"`/`"=d"` outputs and an
empty template with operands as a value passthrough (`tests/pathb-qbe/cases/asm_barrier.cpp`, `asm_ext.cpp`, `traps/asm_ud2.cpp`), and
refuses any other instruction, a register clobber or `goto` (`tests/mruby/pathb-edge/r_unsupported_asm*.ir`,
`tests/pathb-ir/gaps.cpp`); list in `pathb-hosted.md`, "Inline asm". The gcc backend passes asm through.

**`volatile`**
- Path A qbe: for EDG-generated C, cproc rejects stores to `volatile` objects ("volatile store is not yet supported").
  `qbe-prep.rb` drops the qualifier only for hand-written `.c` inputs (`NFCXX_C_INPUT`) and keeps volatile locals in memory
  (`tests/c/volatile_setjmp.c`; `realworld.md`, "C inputs"). Not covered: volatile function parameters and `for`
  declarations.
- Path B: every volatile access is a call of a module-local helper, so volatile code is slow; not atomic, not a fence
  (`tests/pathb-qbe/cases/volatile.cpp`, with assembly checks `// ASM-COUNT:`).

**Path B other**: checked (`NFCXX_IR_OVERFLOW=trap`) unsigned or 64-bit signed multiplication is refused; pointer subscripts are not bounds-checked and there is no `undef` (by decision); thread-local
objects are x86-64 ELF only and a thread-local address in a static initializer is refused; only LP64 layouts are emitted
(`pathb-stage3.md`; refusal paths: `tests/mruby/pathb-edge/r_*.ir` via `tests/mruby/run.sh`). Hosted headers now work (`pathb-hosted.md`; `PATHB_HOSTED=0` or
`--freestanding` gives the old EDG-only headers). Still failing there: `_Float128` in kept functions, asm outside the list in
`pathb-hosted.md` ("Known limits"; no test asserts the failures). `__builtin_object_size` answers only for the address of a known
object (else -1/0), TYPE 1 for a member of a global structure is -1 (`builtin_objsize.cpp`); `alias`/`weakref` need a target defined in
the unit and x86-64 ELF (`alias_attr.cpp`, `alias_static.cpp`). `__builtin_trap` is SIGILL on Path B (`traps/builtin_trap.cpp`).

**cproc / qbe backend, other**
- `alignas(16) int x;` on a block-scope local becomes `__attribute__((aligned))`, which cproc rejects ("GNU attribute
  'aligned' is not supported here"); the gcc backend accepts it. Two shapes from libstdc++ are rewritten by `qbe-prep.rb`
  (`realworld.md`). No test asserts the rejection; `tests/lib/new_launder.cpp` uses a union to avoid it
  (`freestanding.md`). Checked by hand with a one-line program on both backends.
- `__builtin_trap` is unknown to cproc (`tests/builtins/trap_compile_only.cpp`, `XFAIL-qbe`); `freestanding.md`'s `panic` uses `abort`.
- `va_arg` of an aggregate works only for integer-class aggregates of at most 16 bytes (`scripts/cproc-vaarg-aggregate.patch`,
  `tests/c/va_struct.c`); floats in the aggregate, larger or over-aligned ones still stop with cproc's error (`realworld.md`).
- Empty classes have size 0 in the C that cproc sees, while EDG folds `sizeof` as 1 (`freestanding.md`; no test asserts it).
- `nfcc` on qbe ignores `-O*` and `-g*` (no optimisation levels, no debug info); `-Wp,` items outside the listed
  preprocessor options are rejected (`tests/c/cc-mode.sh`, `realworld.md`).
- qbe-compiled mruby uses the portable `switch` dispatch, not computed goto (`realworld.md`; `tests/realworld/run_mruby.sh`).

**Driver**: `nfcxx --emit-c` does not pass user `-I` options to `cpfe` (`realworld.md`; no test). Tracing uses GNU `date`
(Linux only) and does not time EDG's front end separately inside `eccp` (`tracing.md`; `tests/trace/run.sh` checks the
spans that exist).

**`nfceval`** (`eval.md`, "Limitations"; `tests/eval/run.sh` covers the supported forms, not the limits): no sandbox
and no run-time timeout; one eval at a time per engine, not thread safe; no overloaded bindings, no generic lambdas or
C varargs as bound functions; host and snippet must use the same backend.

**Hexagon**: no Hexagon SDK, `hexagon-sim` or QuRT; EDG has no Hexagon target, so a 32-bit little-endian stand-in
(`linux_riscv32`) is used; cases that include hosted C++ headers, need GP-relative relocations or template instantiation
(`edg_prelink`) are reported as SKIP by `tests/hexagon/run.sh` (`hexagon.md`).

**Test inputs**: `tests/realworld/*.sh` fetch pinned upstream commits and need network access (SKIP when the fetch fails).
