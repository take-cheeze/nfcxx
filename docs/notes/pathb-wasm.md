# Path B: a WebAssembly emitter

`scripts/pathb-wasm-emit.rb` lowers the nfcxx mid-level IR (`docs/notes/pathb-stage2.md`) to a WebAssembly module, in the
binary format, with sign extension and bulk memory. It runs under the mruby interpreter (`scripts/mrb`), like the QBE
emitter (`docs/notes/pathb-stage3.md`), and writes the module to stdout.

```
scripts/pathb-dump --ir prog.cpp > prog.ir
scripts/mrb scripts/pathb-wasm-emit.rb prog.ir > prog.wasm
node tests/wasm/host.cjs prog.wasm          # runs main, prints its result (or "trap")
```

`tests/wasm/run.sh` does this for each `tests/wasm/*.cpp`. Each test has its expected result in `// EXPECT: N`
(the `g++ -O0` result, except `calls.cpp`, whose import is a stub), or `// TRAP` (main traps), or `// REFUSE: TEXT`
(the emitter refuses with TEXT). The suite skips, rather than fails, without node. `NFCXX_WASM_ASAN=1` runs every
module in the AddressSanitizer mode (below), where a `// ASAN: KIND` test must report KIND; without it those tests are
skipped. A `// ASAN-EXPECT: N` test is a clean program that needs the mode (its `malloc` is the module's only under it): it
runs under `NFCXX_WASM_ASAN=1` and must give N, and is skipped otherwise.

## Representation

The IR's layout is LP64, and the emitter keeps it. Nothing in the front end changes, so the struct offsets, sizes and
pointer widths of the IR are the ones the C++ program has.

| IR type | wasm |
| --- | --- |
| integers up to 4 bytes, `bool` | `i32`, kept canonical: sign- or zero-extended from the width, `bool` 0 or 1 |
| 8-byte integers | `i64` |
| pointers | `i64`; a memory access wraps it to the `i32` address (`i32.wrap_i64`) |
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
- **The layout.** The heap is a fixed region of 64 KB, `[heap_base, heap_base + 65536)`, with `heap_base` the end of the
  static data rounded up to 16. The stack grows down from the shadow towards it. The heap does not grow: `memory.grow`
  would have to grow the shadow with it, and a fixed size keeps the shadow and the stack top as they are. The shadow of the
  heap is poisoned (`0xfa`) from the end of the static data to the end of the heap, so the bytes not yet handed out are
  reported too. For a small program the memory is three pages.
- **Blocks.** A block of `n` bytes is a chunk of `cap + 64` bytes: a 32-byte left redzone, the payload of `cap` bytes
  (`n` rounded up to 16), and a 32-byte right redzone. The first 20 bytes of the left redzone are the header: the size
  `n`, the capacity, the state (0 in use, 1 quarantined, 2 free), a magic word, and the link of the free list or the
  quarantine. The header is written by the allocator, which is not instrumented. The shadow of a chunk is `0xfa` over the
  redzones, 0 over the payload's whole granules and `n % 8` in the next one, so a block of `n` bytes is addressable exactly
  as a static object is.
- **Free and reuse.** `free` poisons the payload's granules with `0xfd` and puts the block in the quarantine, a FIFO of
  freed blocks. While the quarantine holds more than 4 KB of chunks, its oldest block moves to the free list (LIFO).
  `malloc` takes the first block of the free list whose capacity fits, and otherwise the next chunk at the bump pointer.
  When the heap has no room, `malloc` returns 0.
- **Bad frees.** `free(0)` does nothing. A free of an address that is not the payload of a block in use is reported and
  traps: an address below the first block or at or past the bump pointer, one that is not 16-aligned, and one whose
  header has no magic word (an address inside a block). A free of a block that is already quarantined or on the free list is
  a double free.

| Code | Kind reported |
| --- | --- |
| `0xf1` | `stack-buffer-overflow` |
| `0xf9` | `global-buffer-overflow` |
| `0xf5` | `stack-use-after-return` |
| `0xfa` | `heap-buffer-overflow` (a heap redzone; libasan has `0xfa` and `0xfb`, and reports both as this kind) |
| `0xfd` | `heap-use-after-free` |
| `0x100` | `attempting-double-free` (an allocator report: a free of a block that is not in use, not a shadow code) |
| `0x101` | `attempting-free-on-address-which-was-not-malloc` (an allocator report, not a shadow code) |

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
- A use of a heap block after its free, while the block is quarantined or on the free list (its granules are `0xfd`).
- A double free and a free of an address the allocator did not return, for a block that has not been handed out again.
- Tests: `tests/wasm/asan_*.cpp` (the `// ASAN: KIND` markers). `asan_clean.cpp` and `asan_heap_clean.cpp` are clean and
  give their EXPECT value under the mode; `asan_heap_clean.cpp` has `// ASAN-EXPECT: N`, which runs under
  `NFCXX_WASM_ASAN=1` only (without the mode its `malloc` is the host's stub, so the program has no meaning there).

**Not covered.**
- Reuse. Once the quarantine has evicted a block and `malloc` hands it out again, a stale pointer to it aliases the new
  block, which is in use, so an access through the stale pointer is not reported (checked: after 51 other frees a stale
  read returns the new block's value). A double free of such a block is taken as a free of the new owner's block, and is
  not reported (checked: it returns normally). The quarantine is 4 KB of chunks, so the window is short.
- Heap exhaustion. `malloc` returns 0 when the 64 KB are used, and the program's use of that null pointer is not reported
  (the null page is not checked).
- `memory.grow`, `realloc`, `calloc`, `operator new` and `operator delete`. None of them is in the module: they are
  imports, and the host's stub returns its argument plus one, so the harness cannot give them a heap. Their memory is not
  checked.
- Redzones are 32 bytes, on the heap and on the stack. An index that jumps over one lands in the next object, and is not
  reported.
- Use after scope: the emitter has no scope markers (`scope-end`), so a block's locals are not poisoned at its end.
- Use after return once another call has reused the frame. There is no quarantine for frames.
- Stack exhaustion: the stack growing into the heap or the static data is not detected.
- The null page, addresses below 16. Accesses into the shadow itself (the top 1/8 of the memory) are not checked.
- The allocator's own code is not instrumented, and the header of a block is written without a check.
- Uninitialized reads, leaks and the other checks of libasan.

## Emscripten (`--emscripten`)

`scripts/mrb scripts/pathb-wasm-emit.rb --emscripten prog.ir > prog.wasm` emits the same module with the exports the
Emscripten JS runtime reads. `--emscripten-import-memory` (with `--emscripten`) imports the memory as `env.memory`
instead of exporting it, the layout of Emscripten's `IMPORTED_MEMORY`. The layout and the code are unchanged; without
the arguments the module is byte-identical to the one before the mode existed. `--asan` and `--emscripten` are refused
together (the shadow would sit where the heap begins), and `--emscripten-import-memory` without `--emscripten` is an
error. `NFCXX_WASM_EMSCRIPTEN=1` in `tests/wasm/run.sh` emits every test with `--emscripten`, and
`NFCXX_WASM_EMSCRIPTEN=import` with `--emscripten-import-memory`; each module is checked by `tests/wasm/emscripten.cjs`.

| Export | Kind | Value |
| --- | --- | --- |
| `memory` | memory | the linear memory, exported (not with `--emscripten-import-memory`) |
| `__indirect_function_table` | table, funcref | empty: 0 elements, no maximum |
| `__stack_pointer` | global, mutable i32 | global 0, the stack pointer, at the top of the memory |
| `__data_end` | global, immutable i32 | the end of the static data (the first address after the last object) |
| `__heap_base` | global, immutable i32 | the top of the memory, which is also the initial stack pointer |
| `__wasm_call_ctors` | function, `() -> ()` | empty: runs no static constructors (see below) |

With `--emscripten-import-memory` the module imports `env.memory` (no maximum, initial size the module's pages) and has
no memory section or `memory` export. Growing it is the host's `memory.grow`; the module does not grow it.

- **The table.** The emitter refuses indirect calls (`Fn#call`) and function addresses (`op_type`, and a static
  initializer of `&"f"`), and it emits no `call_indirect`. So no module code calls through the table, and no function is
  stored in it: the table has no element segment, and no call through it can trap. It is exported empty, with no
  maximum, so the JS side can grow it (`tests/wasm/emscripten.cjs` grows it by one). Whether the Emscripten glue uses
  the table at all is not checked (point 3 below).
- **Constructors.** The IR has no list of static constructors: a dynamically initialized global is refused (`(unsupported
  init ...)`, see "What is refused"), so there is nothing for `__wasm_call_ctors` to run. It is exported as an empty
  function that returns and leaves the stack pointer alone.
- **The stack pointer's type is i32, not the pointer type i64.** The IR's pointer values are i64 (LP64 is kept), but the
  stack pointer only ever holds a linear-memory address, and a memory address is i32 in this module already (a memory
  access wraps the i64 to i32). So the prologue is unchanged, and the glue's i32 is met. The consequence is that the
  two kinds of pointer differ in wasm: a `T*` argument of an exported function is an i64, which a JS caller passes as a
  BigInt, not a Number. Making the stack pointer i64 would have meant an i64 prologue and a wrap at each memory access,
  and would have broken the i32 the glue reads.
- **The heap base.** There is no allocator in the module, and the stack grows down from the top of the memory to the
  static data. So the heap is placed where the stack starts: `__heap_base` is the top of the memory (`pages * 65536`).
  The heap is empty at the start: it has no room until the memory grows, and nothing in the module grows it.
- **The imports** are functions of module `env` that the IR calls without defining (the memory with
  `--emscripten-import-memory`). No `wasi_snapshot_preview1` import is added. Under `--emscripten` each import name is
  looked up in `EMSCRIPTEN_IMPORT_NAMES`, a table of IR name to Emscripten name; it is empty (point 5).
- **Names.** A function of the IR may not take an export name of the mode (`EMSCRIPTEN_EXPORTS`): the module is refused.

**The list for step 2, and where each point stands.** Checked against the module, not against an Emscripten JS runtime:
none is installed here, and the Emscripten sources were not reachable from this environment (see "Unverified names").

1. **Pointer width: open, out of scope.** The IR's pointer values are i64 (LP64), where the Emscripten wasm32 glue treats
   pointers as i32 numbers. A pointer crossing the JS boundary is a BigInt. Only the stack pointer and the globals are i32.
   Changing it changes the data model.
2. **Memory import: closed.** `--emscripten-import-memory` imports `env.memory` with no maximum, at the module's pages.
   `tests/wasm/emscripten.cjs` checks the import (name, kind, no maximum, and that the memory it is instantiated with is
   the one `__heap_base` ends), and `NFCXX_WASM_EMSCRIPTEN=import` runs every test in this layout. Default is still export.
3. **The table: documented, unreachable.** No call through the table is emitted, so an empty table is never called. The
   table has no maximum, so a JS-side grow works (the checker grows it). Whether the glue calls `addFunction` is not
   checked here, since no glue is run.
4. **Linking sections: open, out of scope.** No `dylink.0`, `linking` or `reloc.*` custom section. That is needed for
   dynamic linking (`MAIN_MODULE`, `SIDE_MODULE`) only.
5. **Runtime imports: open.** `EMSCRIPTEN_IMPORT_NAMES` is empty: no IR name is mapped, because no pair (IR name, Emscripten
   name) could be verified. Emscripten's libc (`printf`, `malloc`, `memcpy`, ...) is linked into the module, so those
   names are not imports under Emscripten at all; a program that calls them, or `__cxa_*`, does not instantiate under an
   unmodified runtime and needs the import mapped or provided. The emitter does not claim otherwise.
6. **Exports the glue calls: partly closed.** `__wasm_call_ctors` is exported (empty, point "Constructors"). Not exported,
   on purpose: `malloc` and `free` (no allocator here, see point 7), and the `emscripten_stack_*` functions (they need
   stack limits, point 8). `main` is there.
7. **Memory growth: open.** The module has no allocator and no call that grows the memory. An `emscripten_resize_heap`
   import would be unused (nothing in the module calls it), and an export under that name would be an interface the
   runtime does not define on that side, so neither is added. The memory grows only in the host (with the import). The
   heap that `__heap_base` marks is empty, so an `sbrk`-style allocator would need the memory grown first.
8. **Stack limits: open.** `__set_stack_limits` is not exported. The module has no stack-overflow check and no place for
   limits to be read from: a stored limit that nothing reads would be a fake, so the export is left out.

**Unverified names.** The Emscripten runtime names above (`emscripten_resize_heap`, `__set_stack_limits`,
`emscripten_stack_get_current`, the `__syscall_*` and `fd_write` imports, and the libc behavior in point 5) are not
verified here: no `emcc` is installed, `emscripten.org` did not resolve, and the Emscripten source was not reachable
(the raw GitHub path returned 404, and the GitHub API was not enabled for this session). None of them is added to the
module or to `EMSCRIPTEN_IMPORT_NAMES`.

## What is handled

Scalars, pointers and their arithmetic (`offset`, `index`, `pdiff`), the integer and float operators, comparisons,
conversions (`iconv`, `i2f`, `u2f`, `fconv`, `cf2i`, `p2i`, `i2p`, `bitcast`), `load`, `store`, `copy` (`memory.copy`),
slots, direct calls, `if`, `loop` with `break` and `continue`, `return`, and the checks above.

Two forms of `goto` are handled because the front end produces them for `break` and `continue`: a jump to the label at
the end of a loop body, and a jump to the label just after a loop or a switch. Any other `goto`, and any other label, is
refused.

`switch` (`docs/notes/pathb-stage2.md`, section 2). The markers `(case (const T V))` and `(default)` may sit in blocks of
the body; the body's statements are split into arms at them. The selector is compared with each case value in order by
a compare chain: `br_if` to the arm, else `br` to the default arm, or out of the switch when there is none. The arms are
blocks nested so that arm k starts right after the end of its block, and an arm falls into the next one. An arm that is
not empty must end in a jump (`break`, `continue`, `return`, `unreachable`, `trap` or `goto`, also inside a block or in
both branches of an `if`), or be the last arm; otherwise the emitter refuses the fallthrough. `break` inside a switch
leaves it (its label stack entry is the switch's), and `continue` goes to the enclosing loop's step.

## What is refused (the next steps)

Each refusal names the node on stderr and exits with status 3. None is dropped silently.

- General `goto` and labels: the jumps other than the ones above, and a switch whose arm falls into the next non-empty one.
  The structurizer that `pathb-stage2.md` section 2 asks for is needed for these.
- A use of an extern global (`(extern)`, declared here and defined elsewhere), of a dynamically initialized one
  (`(unsupported init ...)`), of a thread-local one, or of a function's address in a static initializer (`addr` to `&"f"`).
  A declaration that nothing uses is not refused: it has no storage, and the QBE path drops it the same way.
- Aggregate parameters, results and arguments (`byval`, `sret`), and aggregate values in registers.
- Variadic calls, indirect calls and function addresses (a table would be needed).
- Bit-fields (`bfload`, `bfstore`), inline assembly, VLAs and exceptions, and the 16-byte types.
- `cf2i` to a type narrower than 32 bits: the range check for the narrow target is not lowered yet.
- A jump to the label after a loop from outside that loop (only the jumps from inside it are handled).

The IR's own `(unsupported ...)` markers are refused the same way, with the marker's text. Those come from the front end,
not from this emitter. Two of them found while writing the tests: a bool-to-integer conversion such as `return x < 0;`
lowers to `(unsupported cast)` (the cast cases in `be/nfcxx_ir.c` do not cover that operand), and the QBE path refuses it
too. The tests write such expressions as `? 1 : 0`.

## Checks

`tests/wasm/run.sh` (`NFCXX_WASM_EMSCRIPTEN=1` for the `--emscripten` mode, see above) compiles each test with the harness (`scripts/setup-pathb.sh`), emits it, validates and runs it under
node, and compares the result with the expectation. The tests for the statics (`globals_*.cpp`) cover an array with an
initializer, a struct with a pointer to another global, a string read through a pointer, an address with an addend, a
float and a negative value, bit-field items, and an 80 KB object that grows the memory. The switch tests
(`switch_*.cpp`) cover several cases with a default, an empty case, a switch in a loop with `break` and `continue`, nested
switches on a long selector, and a return in each arm. `refuse_switch_fallthrough.cpp` and `refuse_global.cpp` check the
two refusals. Node instantiates a module only after validating it, so a malformed
module fails the test. `tests/wasm/frames.cpp` makes 1000 calls with 256 bytes of locals each: the frames must be released
for it to pass in 128 KB.

Sweep over the 262 IR files in the repo (`tests/pathb-ir`, its borrow goldens, `tests/mruby/pathb-edge`): 46 emit, and
every module validates; 168 are refused for the gaps above; 48 are malformed IR (the edge cases that test the parser,
which exit with status 1 as the QBE emitter does). Before the statics and the switch were lowered, the sweep had 34 emit,
197 refused and 31 malformed: 17 of the malformed files are `e_*` edge cases that the refusal of `global` hid until now.

Not done: a C library for the modules (a program that prints goes through an import), and an oracle in Python. The
emitter is not checked byte for byte against another implementation; the node run is the check.
