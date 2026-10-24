# Path B: a WebAssembly emitter

`scripts/pathb-wasm-emit.rb` lowers the nfcxx mid-level IR (`docs/notes/pathb-stage2.md`) to a WebAssembly module, in the
binary format, with sign extension and bulk memory. It runs under the mruby interpreter (`scripts/mrb`), like the QBE
emitter (`docs/notes/pathb-stage3.md`), and writes the module to stdout.

```
scripts/pathb-dump --ir prog.cpp > prog.ir
scripts/mrb scripts/pathb-wasm-emit.rb prog.ir > prog.wasm
node tests/wasm/host.cjs prog.wasm          # runs main, prints its result (or "trap")
```

`--names` adds the custom `name` section (function names: the imports, the IR's functions, and the `--asan` runtime's),
so that an engine's stack trace names the functions (`at _Z4deepi (wasm://...)`); the wasm explorer uses it.

`tests/wasm/run.sh` does this for each `tests/wasm/*.cpp`. Each test has its expected result in `// EXPECT: N`
(the `g++ -O0` result, except `calls.cpp`, whose import is a stub), or `// TRAP` (main traps), or `// REFUSE: TEXT`
(the emitter refuses with TEXT). The suite skips, rather than fails, without node. `NFCXX_WASM_ASAN=1` runs every
module in the AddressSanitizer mode (below), where a `// ASAN: KIND` test must report KIND; without it those tests are
skipped. A `// ASAN-EXPECT: N` test is a clean program that needs the mode (its `malloc` is the module's only under it): it
runs under `NFCXX_WASM_ASAN=1` and must give N, and is skipped otherwise.

## Representation

The IR's layout is LP64 by default, and the emitter keeps it: the struct offsets, sizes and pointer widths of the IR are
the ones the C++ program has on x86-64. `--emscripten` emits the ILP32 layout instead (pointers and `long` 4 bytes), from
the same front end with EDG's `linux_riscv32` target; see "Emscripten" below.

| IR type | wasm |
| --- | --- |
| integers up to 4 bytes, `bool` | `i32`, kept canonical: sign- or zero-extended from the width, `bool` 0 or 1 |
| 8-byte integers | `i64` (`long` and `unsigned long` are 4 bytes, `i32`, under `--emscripten`) |
| pointers | `i64`; a memory access wraps it to the `i32` address (`i32.wrap_i64`). Under `--emscripten`: `i32`, the address itself |
| `float`, `double` | `f32`, `f64` |

- A register is a wasm local. The IR is not SSA, so a register may be set more than once, which a wasm local allows.
- A slot is a frame in the linear memory. The memory is two pages (128 KB), or more when the static data needs it (below).
  A shadow stack grows down from its top (global 0). A function's frame starts at the stack pointer it found on entry,
  minus its frame size, aligned to 16, and the stack pointer is restored before each return and at the end of a void
  function.
- A static object (a defined global with an initializer, or string data) is at a fixed address: the objects are laid
  out in the order of the IR forms, from address 16 (address 0 is no object), each at its alignment. `@"x"` is the i64
  address of the object. Its contents are a data segment, written from the IR's `(init ITEM*)` (`scalar`, `addr`,
  `bytes`, `zero` and `bitfield` items; the bit-fields of a byte are ORed together). The memory starts zeroed, so only
  the objects with a nonzero byte get a segment. The stack keeps at least 64 KB above the static data: the memory is
  two pages, and grows to `ceil((end of the static data + 64 KB) / 64 KB)` pages when the data is larger.
- A function the module defines is exported under its IR name. A function it calls without defining is an import from
  module `env`, with the signature of its first call. The host supplies the imports.

## Traps

Division by zero, `INT_MIN / -1`, a float-to-integer conversion out of range or from NaN, `unreachable` and `trap` trap
through wasm's own traps. A shift count not below the width of the left operand, a null `nonnull` pointer and an index
outside `bounds` trap through an explicit `unreachable`.

The checked arithmetic `cadd csub cmul cneg` (`NFCXX_IR_OVERFLOW=trap`, and `nsw` in `llvm-to-pathb.rb`) traps when the
exact result does not fit the type, signed or unsigned. Below 64 bits the exact result is computed in i64 and its range
is checked. At 64 bits the wrapped result is checked: `cadd` and `csub` by the signs of the operands and the result (or
the carry, unsigned), `cmul` by dividing the result by the left operand (`INT64_MIN * -1` traps in that division).

## AddressSanitizer (`--asan`)

`scripts/mrb scripts/pathb-wasm-emit.rb --asan prog.ir > prog.wasm` emits the module in an AddressSanitizer-style mode.
The mruby interpreter has no `ENV`, so the mode is an argument; `tests/wasm/run.sh` passes it when `NFCXX_WASM_ASAN=1`.
Without the argument the module is byte-identical to the one before the mode existed. The mode is the wasm part of
`docs/notes/asan-plan.md`: no libasan runs on wasm, so the runtime is in the module. It checks the stack, the static data
and the heap.

**Shadow.** The shadow of an address `a` is the byte at `shadow_base + a / 8`, one byte per 8-byte granule, as in libasan:
0 when the granule is addressable, `k` in 1..7 when its first `k` bytes are, and a poison code otherwise. The shadow takes
the top 1/8 of the memory (`shadow_base = pages * 57344`), and the stack starts at `shadow_base`, growing down towards the
heap. The pages keep 64 KB of stack above the heap, as the default layout keeps it above the static data.

**Statics.** Each static object is 8-byte aligned with a 32-byte redzone before it and after the last one. Its redzone and
partial granules are data segments of the shadow.

**Frames.** Each slot is 8-byte aligned with a 32-byte redzone around it; the frame is a multiple of 16 bytes. The prologue
writes the frame's shadow (one `memory.fill` per run of equal codes). A return writes `0xf5` over the frame's shadow.

**Heap.** `malloc` and `free` are the module's own functions under `--asan`.

- **The decision.** A host import cannot give the module a heap it checks: the redzones, the shadow and the check are
  all in the module's memory. So `malloc` and `free` are functions of the module, and the IR's calls go to them. The
  import list in this mode is `env.__asan_report` only; without `--asan` both are imports, as before. A call takes the
  allocator's signature, `malloc(i64) -> i64` and `free(i64) -> void` (LP64: `size_t` and a pointer), and a call with
  another signature is refused (exit status 3, the message names the signature). A function the IR defines under the
  same name is the IR's own, and no allocator is called for it. Not covered by the allocator: `operator new` and
  `operator delete`, `calloc` and `realloc`, which stay imports (their memory is not checked, see below).
- **The layout.** The heap is a fixed region of 256 KB, `[heap_base, heap_base + 262144)`, with `heap_base` the end of
  the static data rounded up to 16. The stack grows down from the shadow towards it. The heap does not grow: `memory.grow`
  would have to grow the shadow with it, and a fixed size keeps the shadow and the stack top as they are. The shadow of
  the heap is poisoned (`0xfa`) from the end of the static data to the end of the heap, so the bytes not yet handed out
  are reported too. For a small program the memory is six pages (384 KB).
- **Blocks.** A block of `n` bytes is a chunk of `cap + 64` bytes: a 32-byte left redzone, the payload of `cap` bytes
  (`n` rounded up to 16), and a 32-byte right redzone. The first 16 bytes of the left redzone are the header: the size
  `n`, the capacity, the state (0 in use, 1 freed) and a magic word. The header is written by the allocator, which is not
  instrumented. The shadow of a chunk is `0xfa` over the redzones, 0 over the payload's whole granules and `n % 8` in the
  next one, so a block of `n` bytes is addressable exactly as a static object is.
- **Reuse policy: no address is handed out twice in a run.** `malloc` only bumps the pointer, and `free` never returns
  memory to it. A freed block stays in the state "freed", with its payload granules `0xfd`, for the rest of the run. So a
  stale pointer to a freed block is reported on every access, however many blocks have been allocated since, and a second
  `free` of the same pointer is reported as `attempting-double-free`, because the block it names is still freed.
  Why this and not a reuse with a check: a wasm address is a plain `i32` with no room for a generation or a tag, so a
  reused address cannot tell a stale pointer from the new owner's. Checking a per-allocation id would need pointer tags,
  which change every access. A larger quarantine only shortens the window in which a stale pointer aliases a new block.
  The cost is memory: the chunks of a run add up to at most 256 KB, so a program that allocates more than that in total,
  freed or not, is reported as out of memory (below). A program with a 1000-pair malloc/free loop of 80-byte chunks fits.
- **Exhaustion policy: report and trap.** A request the heap cannot hold (more than 256 KB, or a chunk that does not fit
  below the heap's end) reports `allocator-out-of-memory` with the requested size as the report's address, and traps
  (`unreachable`), as libasan does when `allocator_may_return_null` is false, its default. So under `--asan` `malloc` never
  returns 0: a program that tests the result for NULL does not get the chance to handle it, because the report comes
  first. This is a decision, not a fix: a program whose contract is that NULL is a normal answer would need an opt-out in
  the style of `allocator_may_return_null`, which the emitter does not have. Without `--asan` `malloc` is the host's import
  and the program's NULL check is unchanged.
- **Bad frees.** `free(0)` does nothing. A free of an address that is not the payload of a block in use is reported and
  traps: an address below the first block or at or past the bump pointer, one that is not 16-aligned, and one whose
  header has no magic word (an address inside a block). A free of a block that is already freed is a double free, whether
  or not the address was handed out again: there is no second block at that address.

| Code | Kind reported |
| --- | --- |
| `0xf1` | `stack-buffer-overflow` |
| `0xf9` | `global-buffer-overflow` |
| `0xf5` | `stack-use-after-return` |
| `0xfa` | `heap-buffer-overflow` (a heap redzone; libasan has `0xfa` and `0xfb`, and reports both as this kind) |
| `0xfd` | `heap-use-after-free` |
| `0x100` | `attempting-double-free` (an allocator report: a free of a block that is not in use, not a shadow code) |
| `0x101` | `attempting-free-on-address-which-was-not-malloc` (an allocator report, not a shadow code) |
| `0x102` | `allocator-out-of-memory` (an allocator report: the requested size is the address, size 0) |

**Checks.** Every load, store, and both ranges of a `copy`, calls the module's check function, `check(addr, size)`, before
the access. The check is the function after the defined ones, and the allocator's `malloc` and `free` follow it. The check
reads the shadow of each granule the access touches. A granule holding a partial count `k` is ok when the access ends
within the first `k` bytes. On a violation the check calls `env.__asan_report(addr, size, code)` and then `unreachable`:
a violation traps, and does not continue. For a partial granule the code is the one of the next granule (the redzone
after the object), so the kind does not depend on the partial count. The allocator reports its bad frees the same way,
with size 0. The host (`tests/wasm/host.cjs`) records the call and prints the access (or the free) and `asan: KIND` as its
last line. A host of an ASan module must provide `env.__asan_report`; a plain module does not import it.

**Covered.**
- Overflows of stack slots, static objects and heap blocks, reads and writes, including the partial last granule of an
  object or block whose size is not a multiple of 8, and an access that starts inside a block and ends past it.
- A `copy` that writes past its destination.
- A use of a slot's address after its function has returned, while no other call has reused the frame.
- A use of a heap block after its free, for the rest of the run, including after the allocator has moved on to other
  blocks (`asan_heap_reuse_read.cpp`: the freed block is evicted from the old 4 KB quarantine and a new block is allocated,
  and the stale read is still reported; the old design returned the new block's value).
- A double free, including of a block freed and then followed by other allocations (`asan_double_free_reuse.cpp`), and
  a free of an address the allocator did not return.
- Heap exhaustion: an allocation the heap cannot hold is reported and traps (`asan_heap_exhausted.cpp`).
- Tests: `tests/wasm/asan_*.cpp` (the `// ASAN: KIND` markers). The clean programs give their EXPECT value under the mode:
  `asan_clean.cpp`, `asan_heap_clean.cpp` (1000 malloc/free pairs, and the partial granules) and `asan_heap_free_clean.cpp`
  (blocks freed and allocated again within the heap). `asan_heap_clean.cpp` and `asan_heap_free_clean.cpp` have
  `// ASAN-EXPECT: N`, which runs under `NFCXX_WASM_ASAN=1` only (without the mode their `malloc` is the host's stub, so the
  program has no meaning there).

**Not covered.**
- Total heap use. The heap is 256 KB of chunks per run, not a peak: a program that frees its blocks but allocates more
  than 256 KB in all traps with `allocator-out-of-memory`. A bigger heap, or a `memory.grow` that also grows the shadow,
  would lift the limit; neither is done.
- NULL from `malloc` under the mode. The mode traps instead (see the exhaustion policy). Programs that rely on a NULL
  return are not run under `--asan`.
- `memory.grow`, `realloc`, `calloc`, `operator new` and `operator delete`. None of them is in the module: they are
  imports, and the host's stub returns its argument plus one, so the harness cannot give them a heap. Their memory is not
  checked.
- Redzones are 32 bytes, on the heap and on the stack. An index that jumps over one lands in the next object, and is not
  reported.
- Use after scope: the emitter has no scope markers (`scope-end`), so a block's locals are not poisoned at its end.
- Use after return once another call has reused the frame. There is no quarantine for frames.
- Stack exhaustion: the stack growing into the heap or the static data is not detected.
- The null page, addresses below 16. Accesses into the shadow itself (the top 1/8 of the memory) are not checked, and
  neither are the pages a host adds after it with `memory.grow` (the wasm explorer's `mmap` binding, TinyGo's heap): the
  check returns at once for an address at or above the shadow's base.
- The allocator's own code is not instrumented, and the header of a block is written without a check.
- Uninitialized reads, leaks and the other checks of libasan.

## Emscripten (`--emscripten`)

`scripts/mrb scripts/pathb-wasm-emit.rb --emscripten prog.ir > prog.wasm` emits the module with the exports the Emscripten
JS runtime reads, in the ILP32 data model of wasm32: pointers and `long` are i32. Its input is ILP32 IR:
`scripts/pathb-dump --freestanding --target linux_riscv32 --ir prog.cpp > prog.ir`. The emitter reads the model from the
IR's `(layout ...)` header. LP64 IR under `--emscripten` is refused, and ILP32 IR without it is refused (LP64 is the
default and is emitted as before). `--emscripten-import-memory` (with `--emscripten`) imports the memory as `env.memory`
instead of exporting it, the layout of Emscripten's `IMPORTED_MEMORY`. The layout and the code are the same in both
models. Without the arguments the module is byte-identical to the one before the mode existed. `--asan` is LP64 only: its
shadow and runtime take i64 addresses, so it is refused with ILP32 (ILP32 needs `--emscripten`, and `--asan` and
`--emscripten` are refused together, since the shadow would sit where the heap begins). `--emscripten-import-memory`
without `--emscripten` is an error. `NFCXX_WASM_EMSCRIPTEN=1` in `tests/wasm/run.sh` emits every test with `--emscripten`
from the ILP32 IR, and `NFCXX_WASM_EMSCRIPTEN=import` with `--emscripten-import-memory`; each module is checked by
`tests/wasm/emscripten.cjs`.

| Export | Kind | Value |
| --- | --- | --- |
| `memory` | memory | the linear memory, exported (not with `--emscripten-import-memory`) |
| `__indirect_function_table` | table, funcref | empty: 0 elements, no maximum |
| `__stack_pointer` | global, mutable i32 | global 0, the stack pointer, at the top of the memory |
| `__data_end` | global, immutable i32 | the end of the static data (the first address after the last object) |
| `__heap_base` | global, immutable i32 | the top of the memory, which is also the initial stack pointer |
| `__wasm_call_ctors` | function, `() -> ()` | empty: runs no static constructors (see below) |
| `stackSave`, `stackRestore`, `stackAlloc` | functions | the stack pointer: read, set, and moved down (aligned to 16) |
| `emscripten_stack_init`, `emscripten_stack_get_base`, `_get_end`, `_get_free` | functions | the stack limits: init is empty, the base is the top, the end is `data_end` rounded up to 16, and free is the distance from the stack pointer to the end |

With `--emscripten-import-memory` the module imports `env.memory` (no maximum, initial size the module's pages) and has
no memory section or `memory` export. Growing it is the host's `memory.grow`; the module does not grow it.

- **The table.** It is the module's function table ("What is handled", function pointers): empty when the module takes
  no function's address, else slot 0 null and the functions from slot 1, which the module's `call_indirect` uses. It
  is exported with no maximum, so the JS side can grow it (`tests/wasm/emscripten.cjs` checks the slots and grows it by
  one). A function the glue adds (`addFunction`) goes to a slot the module's pointers never name. Whether the
  Emscripten glue uses the table at all is not checked (point 3 below).
- **Constructors.** The IR has no list of static constructors: a dynamically initialized global is refused (`(unsupported
  init ...)`, see "What is refused"), so there is nothing for `__wasm_call_ctors` to run. It is exported as an empty
  function that returns and leaves the stack pointer alone.
- **The stack pointer's type is i32.** Under LP64 (the default) the IR's pointer values are i64, but the stack pointer
  only ever holds a linear-memory address, and a memory address is i32 in this module already (a memory access wraps the
  i64 to i32). So the prologue is unchanged, and the glue's i32 is met. The consequence under LP64 is that the two kinds
  of pointer differ in wasm: a `T*` argument of an exported function is an i64, which a JS caller passes as a BigInt, not
  a Number. Making the stack pointer i64 would have meant an i64 prologue and a wrap at each memory access, and would have
  broken the i32 the glue reads. Under `--emscripten` the pointers are i32 too, so the two agree.
- **The heap base.** There is no allocator in the module, and the stack grows down from the top of the memory to the
  static data. So the heap is placed where the stack starts: `__heap_base` is the top of the memory (`pages * 65536`).
  The heap is empty at the start: it has no room until the memory grows, and nothing in the module grows it.
- **The imports** are functions of module `env` that the IR calls without defining (the memory with
  `--emscripten-import-memory`). No `wasi_snapshot_preview1` import is added. Under `--emscripten` each import name is
  looked up in `EMSCRIPTEN_IMPORT_NAMES`, a table of IR name to Emscripten name; it is empty (point 5).
- **Names.** A function of the IR may not take an export name of the mode (`EMSCRIPTEN_EXPORTS`): the module is refused.

**Pointer width: feasibility (step 3).** The data model comes from EDG, not from the emitter. The IR's `(layout ...)`
header prints EDG's `targ_sizeof_*` for the target that cpfe runs with, and `--target` is a run-time option of the same
cpfe: `3rd/edg/src/defines.h` has the tables of every target (`TARG_SIZEOF_LONG_linux_riscv32 4`,
`TARG_SIZEOF_POINTER_linux_riscv32 4`, `TARG_ALIGNOF_LONG_LONG_linux_riscv32 8`), and `bases/docker/dev-env/gcc`'s
`lib_linux_riscv32` gives the predefined macros. So an ILP32 IR needs no change to the EDG submodule, and no change to the
front end's default output: `pathb-dump --target linux_riscv32` passes the option, and without it the command is the one
before. Checked: under the target, `tests/wasm/pointers.cpp` has `(long 4) (pointer 4)` and 4-byte pointer slots, and the
`sizeof` values of a struct with a `char`, a `long long` and a `double` (`4 4 8 8 24 8 8 1`) match clang's
`--target=wasm32`. Two EDG settings differ from the host. The riscv32 table has plain `char` unsigned, so the target
passes `--signed_chars` (the x86-64 host and wasm32 have it signed: `clang --target=wasm32` defines no `__CHAR_UNSIGNED__`).
Its `long double` is 16 bytes, which the emitter refuses as it does now. `--target` needs `--freestanding`: the host's C and
C++ library headers are the host target's. Verdict: go, behind `--emscripten`. The default LP64 output is unchanged.

**The list for step 2, and where each point stands.** Checked against the module, not against an Emscripten JS runtime:
none is installed here, and the Emscripten sources were not reachable from this environment (see "Unverified names").

1. **Pointer width: closed under `--emscripten`.** The module is ILP32 (the feasibility note below): pointers, `long` and
   `unsigned long` are i32, so a pointer crossing the JS boundary is a Number, as the wasm32 glue expects. The default LP64
   module still has i64 pointers (a BigInt at the boundary), as before.
2. **Memory import: closed.** `--emscripten-import-memory` imports `env.memory` with no maximum, at the module's pages.
   `tests/wasm/emscripten.cjs` checks the import (name, kind, no maximum, and that the memory it is instantiated with is
   the one `__heap_base` ends), and `NFCXX_WASM_EMSCRIPTEN=import` runs every test in this layout. Default is still export.
3. **The table: documented, unreachable.** No call through the table is emitted, so an empty table is never called. The
   table has no maximum, so a JS-side grow works (the checker grows it). Whether the glue calls `addFunction` is not
   checked here, since no glue is run.
4. **Linking sections: decided, not needed.** No `dylink.0`, `linking` or `reloc.*` custom section. `dylink.0` is what
   dynamic linking (`MAIN_MODULE`, `SIDE_MODULE`) reads. `linking` and `reloc.*` are what a relocatable object carries for
   the linker. The emitter writes one final module, the result of a link, so a static link needs neither. Not checked
   here (no `emcc` or `wasm-ld` is installed): this is the Emscripten and wasm-ld convention.
5. **Runtime imports: open.** `EMSCRIPTEN_IMPORT_NAMES` is empty: no IR name is mapped, because no pair (IR name, Emscripten
   name) could be verified. Emscripten's libc (`printf`, `malloc`, `memcpy`, ...) is linked into the module, so those
   names are not imports under Emscripten at all; a program that calls them, or `__cxa_*`, does not instantiate under an
   unmodified runtime and needs the import mapped or provided. The emitter does not claim otherwise.
6. **Exports the glue calls: closed for the emcc 3.1.6 glue.** The glue reads `__wasm_call_ctors`, `_main`, `memory`,
   `__indirect_function_table`, `__errno_location`, `stackSave`, `stackRestore`, `stackAlloc` and
   `emscripten_stack_init`, `emscripten_stack_get_base`, `_get_end` and `_get_free` (read from its source, `emcc -O0
   -sMODULARIZE`). The module exports all of them but `__errno_location` (no errno here) and `dynCall_*` (no indirect calls).
   `malloc` and `free` are not exported (no allocator here, see point 7).
7. **Memory growth: open.** The module has no allocator and no call that grows the memory. An `emscripten_resize_heap`
   import would be unused (nothing in the module calls it), and an export under that name would be an interface the
   runtime does not define on that side, so neither is added. The memory grows only in the host (with the import). The
   heap that `__heap_base` marks is empty, so an `sbrk`-style allocator would need the memory grown first.
8. **Stack limits: closed, for the glue's functions.** The stack is global 0, growing down from `stack_top` to the end, which
   is `data_end` rounded up to 16 (the glue asserts a 4-byte-aligned end when it writes the stack cookie: found by running
   the glue, `globals_string.cpp`). `emscripten_stack_get_base` is the top, `_get_end` the end, `_get_free` the distance
   from the stack pointer to the end, `emscripten_stack_init` does nothing (nothing to set up), and `stackSave`,
   `stackRestore` and `stackAlloc` read, set and move the stack pointer (`stackAlloc` aligns to 16). The module does not
   check the limit (as before). `__set_stack_limits` is not exported: the 3.1.6 glue does not call it.

**Verified against emcc 3.1.6** (Ubuntu's `emscripten` package, installed here; `emsdk` from GitHub is not reachable).
The glue's imports for a non-standalone build are `env.emscripten_memcpy_big`, `env.emscripten_resize_heap`,
`env.setTempRet0` and `wasi_snapshot_preview1.fd_write`; a `-sSTANDALONE_WASM` build imports only WASI. The names of
point 5 are therefore checked, and none of them is added to `EMSCRIPTEN_IMPORT_NAMES`: the IR's libc names (`printf`,
`malloc`, `memcpy`) still have no Emscripten implementation here. `emscripten_resize_heap` is not called by the module
(it does not grow the memory).

**The glue check (`NFCXX_WASM_EMSCRIPTEN=glue`).** `tests/wasm/run.sh` builds a `MODULARIZE` glue with emcc, instantiates
each `--emscripten` module with it (`tests/wasm/emcc-glue.cjs`) and calls `_main`. That is the real glue, not the
module's own host: 23 tests pass, and the rest are skipped because they import a function the glue does not provide
(the glue's own imports are the list above). Without emcc the mode is skipped. Before the stack exports were added, the
glue failed at `emscripten_stack_init`, and a data end that is not 4-byte aligned failed the stack cookie.

## Memory64 (`--memory64`)

`scripts/mrb scripts/pathb-wasm-emit.rb --memory64 prog.ir > prog.wasm` emits the LP64 module with a 64-bit linear memory
(the memory64 proposal, which node 22 runs without a flag): the memory's limit has the memory64 flag (`0x04`, an i64
minimum), the data segments' offsets are `i64.const`, and a memory access takes its address as the IR's i64 pointer
value, with no `i32.wrap_i64`. The copy of `copy` takes i64 operands. The IR is the default one (`pathb-dump --ir`); the
addresses are the same as in the default module, so only the top of the address range differs. The default output is
byte-identical to the one before the mode existed (checked on the 84 test and asan inputs).

- **The stack stays in i32.** The frame base and the stack pointer are i32 (the memory is far below 4 GB), and a slot's
  address is extended to i64 where it is used as an address. So the prologue is unchanged. This is the stack-pointer
  choice of "The stack pointer's type is i32" above, now made under memory64 as well. A 64-bit stack would need the
  stack pointer i64 and a wrap-free prologue; no test needs it.
- **What the mode shows.** A load from `2^32 + 8` traps (`tests/wasm/memory64_high_address.cpp`, `// MEMORY64-TRAP`).
  The default module wraps that address to 8 and reads it, so the test runs under the mode only. A struct copy through
  pointers to statics and the stack gives the g++ result (`memory64_copy.cpp`).
- **Not combined** with `--asan` (its shadow and checks are i32 address arithmetic) or `--emscripten` (ILP32: the pointers
  are i32 there). `--memory64` with either is refused by the driver.
- **Not done:** an Emscripten `MEMORY64` runtime (the glue's i64 stack pointer, `__heap_base` as i64), and a memory above
  4 GB: the memory is still the module's pages, two by default, and no test grows it.

Checks: `NFCXX_WASM_MEMORY64=1 tests/wasm/run.sh` runs every test in the mode (25 passed, the ASan and Emscripten ones
skipped); `tests/wasm/run.sh` (24 passed) and the ASan and Emscripten modes are unchanged.

## What is handled

Scalars, pointers and their arithmetic (`offset`, `index`, `pdiff`), the integer and float operators, comparisons,
conversions (`iconv`, `i2f`, `u2f`, `fconv`, `cf2i`, `p2i`, `i2p`, `bitcast`), `load`, `store`, `copy` (`memory.copy`),
slots, `alloca` (dynamic stack, released at the return; refused under `--asan`), direct calls, calls through a function
pointer, `if`, `loop` with `break` and `continue`, `return`, and the checks above. `copy` and `zero-fill` take a constant
length or a run-time one (an `unsigned_long` register: `memory.copy` and `memory.fill` take it as it is; under `--asan`
the range is checked with the run-time size). `bitcast` also reinterprets a float as an integer of its size and back
(`i32.reinterpret_f32` and the like).

Function pointers. The functions whose address the IR takes (`&"f"` anywhere but as a call's callee, also in a static
initializer) get the slots of a function table from 1, in order of first use; the table and its element segment are in
the module only when there is one (and under `--emscripten`, which exports the table, always). A function pointer's
value is its slot, an i64 under LP64. Slot 0 stays empty, so a call through a null pointer traps. A call through a
pointer is `call_indirect` with the type of the call's arguments and result, which the engine checks against the
function in the slot (a mismatch traps). Taking the address of a function the module neither defines nor calls is
refused (its signature is not known). `function_pointers.cpp` checks a call through a pointer, a table of pointers in a
static initializer and a pointer passed as an argument. A `let` may take a bare operand (`llvm-to-pathb.rb` copies phi values so),
and a parameter's register may be any `%N` (EDG numbers them from `%0`, `llvm-to-pathb.rb` from `%1`).

Two forms of `goto` are handled because the front end produces them for `break` and `continue`: a jump to the label at
the end of a loop body, and a jump to the label just after a loop or a switch.

A body of labels and gotos with no `loop` or `switch` (the control flow graph `llvm-to-pathb.rb` writes, or a C or C++
`goto`, see `goto_dispatch.cpp`) is lowered as a dispatch, when every label is at the top level of the body. The labels
split the body into segments; a loop runs the segment that a local names, through a `br_table` into nested blocks
(segment j starts at the end of block j), and control falls from one segment into the next as it falls past a label. A
`goto` sets the local and branches to the loop. Any other `goto` and label is refused.

`switch` (`docs/notes/pathb-stage2.md`, section 2). The markers `(case (const T V))` and `(default)` may sit in blocks of
the body; the body's statements are split into arms at them. The selector is compared with each case value in order by
a compare chain: `br_if` to the arm, else `br` to the default arm, or out of the switch when there is none. The arms are
blocks nested so that arm k starts right after the end of its block, and an arm falls into the next one. An arm that is
not empty must end in a jump (`break`, `continue`, `return`, `unreachable`, `trap` or `goto`, also inside a block or in
both branches of an `if`), or be the last arm; otherwise the emitter refuses the fallthrough. `break` inside a switch
leaves it (its label stack entry is the switch's), and `continue` goes to the enclosing loop's step.

## What is refused (the next steps)

Each refusal names the node on stderr and exits with status 3. None is dropped silently. A refusal inside a function
names the function, and the source line of the statement when the IR has `(loc ...)` statements (`NFCXX_IR_LOC=1` of
`pathb-dump`): `refused: variadic call (in _Z4showi, at prog.cpp:6)`. A global or a `data` form that is refused is
refused only when the module uses it (an unused `std::float16_t` constant of a header does not stop the module). The
top-level `abi-type` and `x87-thunk` forms describe the host ABI and are skipped.

- General `goto` and labels in a body that also has a `loop` or a `switch`, or a label inside a nested statement, and a
  switch whose arm falls into the next non-empty one. The structurizer that `pathb-stage2.md` section 2 asks for is
  needed for these.
- A use of an extern global (`(extern)`, declared here and defined elsewhere), of a dynamically initialized one
  (`(unsupported init ...)`), of a thread-local one, or of a function's address in a static initializer (`addr` to `&"f"`).
  A declaration that nothing uses is not refused: it has no storage, and the QBE path drops it the same way.
- Aggregate parameters, results and arguments (`byval`, `sret`), and aggregate values in registers.
- Variadic calls.
- Bit-fields (`bfload`, `bfstore`), inline assembly, VLAs and exceptions, and the 16-byte types.
- `cf2i` to a type narrower than 32 bits: the range check for the narrow target is not lowered yet.
- A jump to the label after a loop from outside that loop (only the jumps from inside it are handled).

The IR's own `(unsupported ...)` markers are refused the same way, with the marker's text. Those come from the front end,
not from this emitter. Two of them found while writing the tests: a bool-to-integer conversion such as `return x < 0;`
lowers to `(unsupported cast)` (the cast cases in `be/nfcxx_ir.c` do not cover that operand), and the QBE path refuses it
too. The tests write such expressions as `? 1 : 0`.

## Checks

`tests/wasm/run.sh` (`NFCXX_WASM_EMSCRIPTEN=1` for the `--emscripten` mode, see above) compiles each test with the harness (`scripts/setup-pathb.sh`), emits it, validates and runs it under
node, and compares the result with the expectation. A test whose result depends on the width of `long` says
`// EXPECT-ILP32: N` as well: under the emscripten modes that is its result (`floats.cpp`: 16 on the host, 15 under ILP32).
The ILP32 expectations were checked with a freestanding `g++ -m32` run (`_start` calls `main` and exits with its result;
no 32-bit libgcc is needed for these programs), and they agree with the LP64 ones except `floats`. The tests for the statics (`globals_*.cpp`) cover an array with an
initializer, a struct with a pointer to another global, a string read through a pointer, an address with an addend, a
float and a negative value, bit-field items, and an 80 KB object that grows the memory. The switch tests
(`switch_*.cpp`) cover several cases with a default, an empty case, a switch in a loop with `break` and `continue`, nested
switches on a long selector, and a return in each arm. `refuse_switch_fallthrough.cpp` and `refuse_global.cpp` check the
two refusals, and `refuse_located.cpp` the function and line a refusal names (the suite dumps a `REFUSE` test with
`NFCXX_IR_LOC=1`). `goto_dispatch.cpp` checks the dispatch lowering, `function_pointers.cpp` the function table, and `checked_arith.ir` (hand-written IR, emitted in the
LP64 modes) checks the checked arithmetic at the edges of each width through `checked_arith.cjs`. Node instantiates a
module only after validating it, so a malformed
module fails the test. `tests/wasm/frames.cpp` makes 1000 calls with 256 bytes of locals each: the frames must be released
for it to pass in 128 KB.

Sweep over the 306 IR files in the repo (`tests/pathb-ir`, the borrow goldens of `tests/pathb-borrow`,
`tests/mruby/pathb-edge`): 62 emit, and every module validates; 196 are refused for the gaps above; 48 are malformed IR
(the edge cases that test the parser, which exit with status 1 as the QBE emitter does). Before the checked arithmetic,
`alloca` and the goto dispatch the same files gave 54, 204 and 48, and before the function table 59, 199 and 48. Before the statics and the switch were lowered, the sweep had 34 emit,
197 refused and 31 malformed: 17 of the malformed files are `e_*` edge cases that the refusal of `global` hid until now.

Not done: a C library for the modules (a program that prints goes through an import), and an oracle in Python. The
emitter is not checked byte for byte against another implementation; the node run is the check.
