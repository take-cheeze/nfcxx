# Safe pointers (`nfcxx -fsafe-pointers`): Fil-C-style checks on Path B

Status: prototype (phases 1 and 2 of the plan at the end). `nfcxx -fsafe-pointers x.cpp -o x` builds a program in which every
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
| use after free | an access or arithmetic on a heap block that was freed: the block stays dead while the collector finds a pointer to it | use after free |
| use after return | an access or arithmetic on the stack below the current frame | use of a stack object after its function returned |
| double free, bad free | `free`/`delete` of a freed block, or of a pointer into a block that is not its start | double free / free of a pointer that is not the start of a heap block |
| call of the wrong type | a call through a function pointer that reaches a function of an instrumented unit whose signature differs from the call's | call through a function pointer of the wrong type |
| call of data | a call through a pointer into a heap block, a global or a stack slot | call of a pointer that is not a function |

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
own. An `offset` of such an address by a constant inside the object is not checked either. Nor is an access through a
register that a pre-pass over the function (`sp_safe_regs`) proves to be such an offset (or a `bitcast` of one), used
for nothing but loads and stores that fit in the slot from there: the access is in bounds by construction, and since
the pointer goes nowhere else, it does not make the slot escape. The same holds for pointers loaded from
`@"__curr_eh_stack_entry"`, the EH stack entry of EDG's exception lowering, which only compiler-generated code and
EDG's runtime touch; and a slot whose address is only stored there (the entry itself) is not registered.

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
     the allocs, `call $__nfcxx_sp_leave(l FIRST-SLOT)` before every `ret`. The storage QBE keeps for a by-value
     aggregate parameter (a by-value iterator's `this` points there), an empty class's buffer and the C sret buffer are
     registered in the same call, with the top bit of the size set: QBE lays them out with no padding byte, so the
     runtime never takes the address one past their end for them (it may be the next object's start);
   - defined globals and strings: `z 1` at the end of the data item, and a table plus a constructor that registers them;
   - every defined function: its address and signature hash in a second table of the same constructor
     (`__nfcxx_sp_funcs`); before every call through a pointer, `call $__nfcxx_sp_call(l CALLEE, l HASH, l FILE, w LINE)`.
     The signature is the QBE class of the result and of each parameter up to `...`, an aggregate by value as its size
     and alignment (`sp_sig`): the ABI shape, made by the same code for the definition and the call, so a call that
     agrees with its callee's ABI always passes. `long double` functions are not registered (their address is the x87
     entry thunk, not the QBE function).

   Without `--safe` the output is byte-identical to before: every hook is gated on `$safe`.
3. The runtime is `lib/safeptr/nfcxx_safeptr.c`, built by `scripts/safeptr-rt` into `build/safeptr/nfcxx_safeptr.o`. The
   driver links it first on a Path B link with the flag, so its `malloc` is the program's.
   - Heap blocks and globals: a hash table of 256-byte granules to the objects that overlap them, and a list for objects
     over 64 KiB. Its memory comes from `mmap`, so `malloc` can update it. One mutex protects it. Each thread caches the
     last object it found, with a generation counter that every `free` bumps, so the common case (the same object again)
     takes no lock.
   - Freed blocks stay in the table as dead. A collection (`collect`, from `free`) runs when more than
     max(4096, live blocks / 4) blocks or max(64 MiB, live bytes / 4) bytes were freed since the last one, so its cost,
     a scan of the live heap, is proportional to what was freed. It marks every dead block that a word of a root points
     into (`[lo, hi]`, one past the end included), and gives the others back to glibc. The roots are the writable
     `PT_LOAD` segments of every loaded module (`dl_iterate_phdr`, listed before the table's lock is taken: a thread in
     `dlopen` holds the loader's lock and may be waiting in `malloc`), the stack of every thread that ran instrumented
     code from the lowest stack pointer it was seen with to its top (the collector's own from its frame, after
     `__builtin_unwind_init` spilled its caller's registers), and the contents of every live heap block. The collector
     never frees what the program did not free, so a root it misses (another thread's registers, memory from `mmap`,
     TLS) can only let a dead block go back early, which makes a later use of it unreported, never a correct program fail.
   - Functions: an open-addressing table from address to signature hash, and a one-entry cache per thread. A callee in
     the table must have the call's hash; a callee that is not in it but lies in a heap block, a global or a stack slot is
     data; any other callee (libc, libstdc++.so, `.c` inputs) is not checked.
   - Stack slots: per thread, the records of the live frames in registration order, and a stack of frames (frames nest,
     so they are ordered by address). The common lookup is the stack's shadow: one 32-bit entry per 4-byte granule of
     the thread's stack (a `MAP_NORESERVE` mapping, 8 MiB for an 8 MiB stack, only touched pages cost memory), written
     with the record's index when a frame registers its slots and never cleared. A check reads the entry for its
     address and takes the record when that record still holds the address; a stale entry (of a frame that returned)
     fails that test, and the lookup falls back to bisecting the frames and scanning the one that holds the address.
     An address between the thread's stack bottom (`pthread_getattr_np`) and the current stack pointer is in a frame
     that returned.
   - The checks' fast paths (the heap cache, the shadow) are leaf code; the slow paths are separate cold functions, so
     the fast path saves no registers. The runtime is built with `-ftls-model=initial-exec`, and the state the fast paths
     read is one thread-local block (`sp_hot`): each access is a load from `%fs`, not a call of `__tls_get_addr`.
   - A failure prints `FILE:LINE: safety error: WHAT (address P)` after flushing stdout, then calls `abort()`.

## Tests

`tests/safeptr/run.sh` (CI: `pathb.yml`, with `SAFEPTR_SWEEP=1`):

- `tests/safeptr/cases/*.cpp` with `// SAFE: text`: the program must abort with that report and name its source file;
  without the flag it must not report. The cases are `heap_overflow`, `heap_arith` (arithmetic from one heap block into
  the next, which redzone-based ASan does not see when the jump is past the redzone), `use_after_free`, `double_free`,
  `stack_overflow` (a local array read through a pointer, past the bounds check's reach), `use_after_return`,
  `global_overflow`, `memcpy_overflow`, `uaf_after_churn` (a dangling pointer in a global, used after 20000 more frees
  than the old quarantine held), `uaf_heap_root` (the dangling pointer is in a live `std::vector`'s buffer),
  `call_wrong_type` (a function taking a pointer called as `int (*)(int, int)`) and `call_data` (a heap block called as
  a function).
- `clean_containers.cpp`, `clean_threads_eh.cpp` (`// EXPECT: 0`): vectors, strings, maps, exceptions through frames
  with escaping locals, deep recursion, `realloc`, four threads. Nothing is reported.
- `clean_byval.cpp`: `std::sort` with by-value iterators and comparators, a by-value aggregate parameter (the unpadded
  storage of by-value parameters next to each other).
- `clean_calls.cpp`: virtual calls with this-adjusting thunks, function pointers, member function pointers,
  `std::function`, `qsort` callbacks, pointers to libc functions. `clean_churn.cpp`: two million 1 KiB blocks allocated
  and freed while a linked list stays live; the peak resident size must stay under 512 MiB (the collector gives the
  unreferenced blocks back).
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
| `nfcxx -fsafe-pointers` | 37 s after phase 1, 30 s after phase 2, 12.5 s after the first speed round, 7 s after the second |

At the end of phase 1 that was about 15x over Path B. The speed round (the first part of phase 4 in the plan below)
took it to about 12.5 s, 5x, by profiling with `callgrind` and removing what it showed:

| change | time |
| --- | --- |
| phase 2 (start of the round) | 30 s |
| access-only offsets of slots, EH stack entries not registered (emitter) | 21 s |
| by-value parameter storage registered (its misses fell through to the locked heap lookup) | 20 s |
| eight-entry stack record cache | 15.5 s |
| bisection inside the top frames instead of a linear scan | 12.5 s |

A second round took it to about 7 s, 2.8x over Path B (`callgrind`: 2.08G instructions against 0.31G for the small
version of the program):

| change | time |
| --- | --- |
| start (after the first round) | 12.5 s |
| the stack's shadow instead of bisecting the frames' records | 10 s |
| fast paths apart from the slow paths (no register saves) | 8–9 s |
| initial-exec TLS (no `__tls_get_addr` call per thread-local read) | 7.5 s |
| no sort of the frames' records (only the rare fallback needed it) | 7.5 s |
| the hot thread-local state in one block | 7 s |

Tried and dropped: an inline fast path in the emitted QBE (a two-entry per-thread cache tested before the call). It
made the program 10% slower (21 s against 19 s on the same runtime): the test is about 20 instructions and a TLS load
per access, and with stack entries dropped at every return its hit rate stayed low, so most accesses paid for both.

What is left (`callgrind`, the small version of the program): `__nfcxx_sp_check` 40% (its fast path is about 40
instructions, run for every unproven access), `__nfcxx_sp_frame` 25% (the variadic argument walk and the shadow
writes of frames with many escaping temporaries). It is mostly the number of calls: Path B has no inlining, so every
iterator operation is a call with checks inside. Fil-C reports 1.5x to 4x, with an optimizing LLVM pipeline.

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
- **Use after free** is found while a pointer to the block is in a root the collector scans. A pointer kept only where
  it does not look (a register of another thread, `mmap` memory, thread-local storage, a heap block of memory not from
  `malloc`, a pointer hidden as an integer it cannot recognize, such as one XORed with a key) lets the block go back to
  glibc, and a later use through it finds whatever was allocated there.
- **Retention**: a freed block stays allocated while any word of a root looks like a pointer into it (conservative,
  as Fil-C's FUGC is for stacks). Memory a long-running program frees but keeps a stale pointer to is never given back.
- **Use after return** is found for addresses below the current stack pointer. A dangling pointer into a frame that a
  later call has reused at the same depth finds that call's objects.
- **Call checks compare ABI shapes**, not C++ types: `int (*)(int *)` called as `int (*)(long)` passes (both take one
  `l`). Callees outside instrumented units are not checked, and a pointer into the middle of a function is not found.
- One lock for the heap table; the per-thread cache keeps it off the common path. A race between a check and a `free` of
  the same block in another thread can pass (the program has a data race on the block anyway).
- Whole programs only: the driver's Path B route has no `-c` (it writes no object, with or without the flag), so a
  program is built from its sources in one command, and that link adds the runtime.

## Plan

1. Done: bounds, provenance at arithmetic, use after free (quarantine), use after return, double free, on Path B, with
   the layout unchanged.
2. Done: a conservative collector decides when a freed block goes back (never while a scanned root points to it), and
   calls through pointers are checked against the callee's signature and against data objects.
3. Capability pointers: a 16-byte `(pointer, object)` pair in the IR for `--freestanding` programs and `lib/`, which are
   compiled entirely from source, so the layout can change. `i2p` then gives a pointer with no object.
4. Whole-program hosted mode: a C library (musl) and the C++ runtime built through Path B, so that nothing is unchecked.
   Speed: two rounds are done ("Cost"); next would be elision of checks that a dominating check covers, and inlining
   on Path B itself, which would remove most of the calls the checks sit in.
