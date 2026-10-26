# Safe pointers (`nfcxx -fsafe-pointers`): Fil-C-style checks on Path B

Status: prototype (phase 1 of the plan at the end). `nfcxx -fsafe-pointers x.cpp -o x` builds a program in which every
pointer has an object, the object it was derived from, and the program stops when it uses a pointer outside that object
or after the object is gone:

```
$ nfcxx -fsafe-pointers heap_arith.cpp -o x && ./x
heap_arith.cpp:8: safety error: pointer arithmetic leaves its object (address 0x55e65ff3a2d0)
Aborted                                   # SIGABRT, status 134, like the ubsan checks
```

The model is [Fil-C](https://fil-c.org)'s: a pointer's capability is its object, arithmetic keeps it, and every access is
checked against it. The difference is where the capability lives. Fil-C carries it with the pointer (InvisiCaps); here it
is looked up by address in a table of the program's objects, so the pointers stay 8 bytes and the layout of every type is
unchanged. The cost of that choice is in "Limits": a pointer that comes back from an integer, or that a single step of
arithmetic moves from one object into another without passing through the check, has the provenance of where it points.

It selects Path B (EDG lowered IL -> IR -> QBE), because the checks are emitted from the IR's typed loads, stores and
pointer arithmetic (`scripts/pathb-qbe-emit.rb --safe`); the generated C of the qbe and gcc backends has no such
operations to instrument.

## What is checked

| error | where it is found | report |
| --- | --- | --- |
| out-of-bounds access | a load, store, bit-field access, `copy`, `zero-fill`, or a call of `memcpy` `memmove` `memset` `memcmp` `bcmp`, through a computed address, that does not fit in its object | out-of-bounds access |
| pointer arithmetic out of the object | `offset` and `index` whose result is outside `[lo, hi]` of the base's object (one past the end is allowed, as C++ allows it) | pointer arithmetic leaves its object |
| use after free | an access or arithmetic on a heap block that was freed and is still in the quarantine | use after free |
| use after return | an access or arithmetic on the stack below the current frame | use of a stack object after its function returned |
| double free, bad free | `free`/`delete` of a freed block, or of a pointer into a block that is not its start | double free / free of a pointer that is not the start of a heap block |

The objects are:

- **heap blocks**: `malloc`, `calloc`, `realloc`, `memalign`, `aligned_alloc`, `posix_memalign`, `valloc`, `pvalloc`,
  `free`, `malloc_usable_size` are defined by the runtime over glibc's `__libc_*` entry points. They are in the
  executable, so they also serve libstdc++.so and EDG's `operator new` in libC.a: a `std::vector`'s buffer is an object.
- **globals and string literals** of instrumented translation units, registered by a constructor of each module
  (`__nfcxx_sp_gctor`, `.init_array.00101`). A COMDAT global defined by several units is registered once.
- **escaping stack slots** of instrumented functions: a slot whose address is used for anything other than the address
  of a load or store of the slot itself. They are registered at entry (`__nfcxx_sp_frame`) and released at each return
  (`__nfcxx_sp_leave`). A frame that a C++ exception leaves (EDG's setjmp/longjmp ABI) never returns. Its records are
  dropped by the next frame entered below it, or by the return of a frame above it.

Every registered object gets one byte of padding (a heap block is allocated one byte longer, a slot and a global get one
more byte). So the address one past an object's end is never the start of another object, and the object of a pointer
is the one with `lo <= p <= hi`, whichever object `p` is.

A load or store whose address is a slot or a global by name (`$"x"`, `@"x"`) is not checked: its type is the object's
own. An `offset` of such an address by a constant inside the object is not checked either.

Memory in no object is not checked. That covers libc's data (`stdout`, `environ`, `getenv` results), thread-local
objects, the stacks of uninstrumented code and memory from `mmap`: the program shares its address space with code built
without the checks, so this is a hardening mode, not Fil-C's guarantee (see "Limits").

## How it works

1. `nfcxx -fsafe-pointers` sets `backend=pathb` and exports `NFCXX_SAFE_POINTERS=1`. `scripts/pathb-cc` then runs the
   front end with `NFCXX_IR_LOC=1` (the IR carries `(loc "FILE" LINE)` statements, `ubsan.md`) and the emitter with
   `--safe`.
2. The emitter (`scripts/pathb-qbe-emit.rb`, section "-fsafe-pointers"):
   - before a load, store, bit-field access, `copy` or `zero-fill` through a computed address:
     `call $__nfcxx_sp_check(l ADDR, l SIZE, l FILE, w LINE)`;
   - after `offset` and `index`: `%r =l call $__nfcxx_sp_derive(l BASE, l RESULT, l FILE, w LINE)`, and `%r` is the
     pointer from then on;
   - before a direct call of `memcpy`, `memmove`, `memset`, `memcmp` or `bcmp`: a check of each pointer argument with the
     length argument;
   - escaping slots: one byte of padding in their `alloc`, `call $__nfcxx_sp_frame(w N, ..., l SLOT, l SIZE, ...)` after
     the allocs, `call $__nfcxx_sp_leave(l FIRST-SLOT)` before every `ret`;
   - defined globals and strings: `z 1` at the end of the data item, and a table plus a constructor that registers them.

   Without `--safe` the output is byte-identical to before: every hook is gated on `$safe`.
3. The runtime is `lib/safeptr/nfcxx_safeptr.c`, built by `scripts/safeptr-rt` into `build/safeptr/nfcxx_safeptr.o`. The
   driver links it first on a Path B link with the flag, so its `malloc` is the program's.
   - Heap blocks and globals: a hash table of 256-byte granules to the objects that overlap them, and a list for objects
     over 64 KiB. Its memory comes from `mmap`, so `malloc` can update it. One mutex protects it. Each thread caches the
     last object it found, with a generation counter that every `free` bumps, so the common case (the same object again)
     takes no lock.
   - Freed blocks stay in the table as dead in a FIFO quarantine of 4096 blocks / 64 MiB before glibc gets them back.
   - Stack slots: per thread, an array sorted from the highest address down (each frame's slots are sorted at entry,
     and frames nest), searched by bisection, and a stack of frames. An address between the thread's stack bottom
     (`pthread_getattr_np`) and the current stack pointer is in a frame that returned.
   - A failure prints `FILE:LINE: safety error: WHAT (address P)` after flushing stdout, then calls `abort()`.

## Tests

`tests/safeptr/run.sh` (CI: `pathb.yml`, with `SAFEPTR_SWEEP=1`):

- `tests/safeptr/cases/*.cpp` with `// SAFE: text`: the program must abort with that report and name its source file;
  without the flag it must not report. The cases are `heap_overflow`, `heap_arith` (arithmetic from one heap block into
  the next, which redzone-based ASan does not see when the jump is past the redzone), `use_after_free`, `double_free`,
  `stack_overflow` (a local array read through a pointer, past the bounds check's reach), `use_after_return`,
  `global_overflow` and `memcpy_overflow`.
- `clean_containers.cpp`, `clean_threads_eh.cpp` (`// EXPECT: 0`): vectors, strings, maps, exceptions through frames
  with escaping locals, deep recursion, `realloc`, four threads. Nothing is reported.
- The driver refuses `--freestanding` and `-fsanitize=address` with the flag.
- `SAFEPTR_SWEEP=1`: every program of `tests/pathb-qbe/cases` and `tests/cases` is built with and without the flag, and
  the exit status and standard output must be the same. 150 of 150 Path B programs agree (`qbe_floatnx_gnu_source.cpp`
  does not build on Path B without the flag either, and is skipped).

The sweep found one bug that was not in the checks: the x87 entry thunk of a `long double` function had no alignment
directive. With more code before it, the thunk landed on an odd address, and a pointer to such a member function was
taken for a virtual one, since the Itanium ABI marks virtual member pointers with the low bit. The thunks are now
`.balign 16`, as QBE aligns functions (`x87_entry_thunk`; `longdouble_call.cpp` showed it).

## Cost

Measured on one program (2M-element `std::vector<int>` sort and 20 passes over it, a 100k-entry
`std::map<int, std::string>`), this machine:

| build | time |
| --- | --- |
| `nfcxx` (qbe backend) | 1.0 s |
| `nfcxx --backend=pathb` | 2.5 s |
| `nfcxx -fsafe-pointers` | 37 s |

That is about 15x over Path B, mostly the number of calls: every element access through an iterator is a call of the
iterator's `operator*`, which registers its frame, plus a `derive` and a `check`. There is no inlining on Path B and no
inline fast path for the checks yet; `callgrind` puts 43% in the stack bisection and 19% in `__nfcxx_sp_check`.
Fil-C reports 1.5x to 4x, with an optimizing LLVM pipeline.

## Limits

Each of these is a false negative: a bad access that is not reported. None of them makes a correct program fail.

- **Provenance is by address.** A pointer made from an integer (`i2p`), or carried through integer arithmetic, has the
  object it points into. Fil-C gives such a pointer no capability.
- **Object granularity.** A pointer to a member may move anywhere inside the whole object: an overflow from one array
  member into the next member is not found (Fil-C is the same).
- **Uninstrumented code**: libc, libstdc++.so, EDG's libC.a, `.c` inputs (they go through cproc), and the out-of-line
  library calls other than the five block functions above (`strcpy`, `std::string` internals in libstdc++.so, ...). Their
  accesses are not checked; their heap blocks are still objects.
- **Not objects**: thread-local variables, `alloca` and C VLA storage (QBE `alloc16` in the body; C++ VLAs are
  `__vla_alloc`, i.e. heap), slots after the 64th escaping slot of one frame, memory from `mmap`, blocks allocated before
  the runtime started.
- **Use after free** is found while the block is in the quarantine. After that its memory can hold a new block, and a
  dangling pointer into it is valid for the new block. Fil-C's collector never reuses memory that a pointer can reach.
- **Use after return** is found for addresses below the current stack pointer. A dangling pointer into a frame that a
  later call has reused at the same depth finds that call's objects.
- Indirect calls are null-checked (Path B's `nonnull`), not checked against the function's type.
- One lock for the heap table; the per-thread cache keeps it off the common path. A race between a check and a `free` of
  the same block in another thread can pass (the program has a data race on the block anyway).
- Whole programs only: the driver's Path B route has no `-c` (it writes no object, with or without the flag), so a
  program is built from its sources in one command, and that link adds the runtime.

## Plan

1. Done (this note): bounds, provenance at arithmetic, use after free (quarantine), use after return, double free, on
   Path B, with the layout unchanged.
2. Memory safety without the quarantine limit: `free` never gives memory back while a pointer may reach it, i.e. a
   conservative mark-sweep collector over the object table (the roots: the registered stacks and globals, and the
   uninstrumented memory conservatively). Type-checked indirect calls: a signature tag on each function entry, compared
   at `nonnull`.
3. Capability pointers: a 16-byte `(pointer, object)` pair in the IR for `--freestanding` programs and `lib/`, which are
   compiled entirely from source, so the layout can change. `i2p` then gives a pointer with no object.
4. Whole-program hosted mode: a C library (musl) and the C++ runtime built through Path B, so that nothing is unchecked.
   Speed: inline fast paths for the checks in the emitted QBE, elision of checks that a dominating check covers.
