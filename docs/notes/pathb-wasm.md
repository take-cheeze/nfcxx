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
skipped.

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
Without the argument the module is byte-identical to the one before the mode existed. The mode is the first slice of the
wasm part of `docs/notes/asan-plan.md`: no libasan runs on wasm, so the runtime is in the module.

**Shadow.** The shadow of an address `a` is the byte at `shadow_base + a / 8`, one byte per 8-byte granule, as in libasan:
0 when the granule is addressable, `k` in 1..7 when its first `k` bytes are, and a poison code otherwise. The shadow takes
the top 1/8 of the memory (`shadow_base = pages * 57344`), and the stack starts at `shadow_base`, growing down. The pages
keep 64 KB of stack above the static data, as in the default layout. Codes: `0xf1` stack redzone, `0xf9` global redzone,
`0xf5` the frame of a function that has returned.

**Statics.** Each static object is 8-byte aligned with a 32-byte redzone before it and after the last one. Its redzone and
partial granules are data segments of the shadow.

**Frames.** Each slot is 8-byte aligned with a 32-byte redzone around it; the frame is a multiple of 16 bytes. The prologue
writes the frame's shadow (one `memory.fill` per run of equal codes). A return writes `0xf5` over the frame's shadow.

**Checks.** Every load, store, and both ranges of a `copy`, calls the module's last function, `check(addr, size)`, before
the access. The check reads the shadow of each granule the access touches. A granule holding a partial count `k` is
ok when the access ends within the first `k` bytes. On a violation the check calls `env.__asan_report(addr, size, code)`
and then `unreachable`: a violation traps, and does not continue. For a partial granule the code is the one of the next
granule (the redzone after the object), so the kind does not depend on the partial count. The host (`tests/wasm/host.cjs`)
records the call and prints the access and `asan: KIND` as its last line. A host of an ASan module must provide
`env.__asan_report`; a plain module does not import it.

| Code | Kind reported |
| --- | --- |
| `0xf1` | `stack-buffer-overflow` |
| `0xf9` | `global-buffer-overflow` |
| `0xf5` | `stack-use-after-return` |

**Covered.** Overflows of stack slots and of static objects, including the partial last granule of an object whose size
is not a multiple of 8, and an access that starts inside an object and ends past it; a `copy` that writes past its
destination; a use of a slot's address after its function has returned, while no other call has reused the frame.
Tests: `tests/wasm/asan_*.cpp` (the `// ASAN: KIND` markers), and `asan_clean.cpp`, which is clean and gives its EXPECT
value in both modes.

**Not covered.**
- Heap. `malloc` and `free` are imports, and the host's stub returns its argument plus one, so the harness has no heap.
  A first slice with an allocator in the module (with redzones, a quarantine and `free` checks) is the next step; it
  would change the import list in ASan mode only.
- Redzones are 32 bytes. An index that jumps over one lands in the next object, and is not reported.
- Use after scope: the emitter has no scope markers (`scope-end`), so a block's locals are not poisoned at its end.
- Use after return once another call has reused the frame. There is no quarantine: the frame's shadow is rewritten by
  the next prologue that covers it.
- Stack exhaustion (the stack reaching the static data is not detected), and the gap between the static data and the
  stack (unpoisoned).
- The null page, addresses below 16. Accesses into the shadow itself (the top 1/8 of the memory) are not checked.
- Uninitialized reads, leaks and the other checks of libasan.

## Emscripten (`--emscripten`)

`scripts/mrb scripts/pathb-wasm-emit.rb --emscripten prog.ir > prog.wasm` emits the same module with the exports the
Emscripten JS runtime reads. It is the first step of the Emscripten compatibility plan. The layout and the code are
unchanged; without the argument the module is byte-identical to the one before the mode existed. `--asan` and
`--emscripten` are refused together (the shadow would sit where the heap begins). `NFCXX_WASM_EMSCRIPTEN=1` in
`tests/wasm/run.sh` emits every test with the flag and runs `tests/wasm/emscripten.cjs` on each module.

| Export | Kind | Value |
| --- | --- | --- |
| `memory` | memory | the linear memory (exported, not imported) |
| `__indirect_function_table` | table, funcref | empty: 0 elements, no maximum |
| `__stack_pointer` | global, mutable i32 | global 0, the stack pointer, at the top of the memory |
| `__data_end` | global, immutable i32 | the end of the static data (the first address after the last object) |
| `__heap_base` | global, immutable i32 | the top of the memory, which is also the initial stack pointer |

- **The table.** The emitter refuses indirect calls (`Fn#call`) and function addresses (`op_type`, and a static
  initializer of `&"f"`), so no function is ever stored in a table and the table has no element segment. It is exported
  empty so that the table accessor the glue uses finds an export under that name. Whether the glue needs it at all is not
  checked (see the list below).
- **The stack pointer's type is i32, not the pointer type i64.** The IR's pointer values are i64 (LP64 is kept), but the
  stack pointer only ever holds a linear-memory address, and a memory address is i32 in this module already (a memory
  access wraps the i64 to i32). So the prologue is unchanged, and the glue's i32 is met. The consequence is that the
  two kinds of pointer differ in wasm: a `T*` argument of an exported function is an i64, which a JS caller passes as a
  BigInt, not a Number. Making the stack pointer i64 would have meant an i64 prologue and a wrap at each memory access,
  and would have broken the i32 the glue reads.
- **The heap base.** There is no allocator in the module, and the stack grows down from the top of the memory to the
  static data. So the heap is placed where the stack starts: `__heap_base` is the top of the memory (`pages * 65536`),
  and an `sbrk`-style allocator would grow the memory from there (the memory is not grown by the module itself). The
  heap is empty at the start: it has no room until the memory grows.
- **The imports** are unchanged: functions of module `env` that the IR calls without defining. No
  `wasi_snapshot_preview1` import is added.
- **Names.** A function of the IR may not take an export name of the mode (`EMSCRIPTEN_EXPORTS`): the module is refused.

**Glue expectations not met** (the list for step 2; checked against the module, not against an Emscripten JS runtime,
since none is installed here):

1. **Pointer width.** The IR's pointer values are i64 (LP64), where the Emscripten wasm32 glue treats pointers as i32
   numbers. A pointer crossing the JS boundary is a BigInt. Only the stack pointer and the globals are i32.
2. **Memory import.** The memory is exported. Emscripten's default is to export it too, but `IMPORTED_MEMORY` (or a
   shared memory) expects `env.memory`; that is not supported.
3. **The table has no entries.** Function pointers are refused, so a call through the table (`addFunction`, a dynamic
   call) would trap; the table is present only so that the accessor finds it.
4. **Linking sections.** No `dylink.0`, `linking` or `reloc.*` custom section. That is needed for dynamic linking
   (`MAIN_MODULE`, `SIDE_MODULE`) only.
5. **Runtime imports.** The module imports every function the IR calls and does not define, under its C++ or C name
   (`printf`, `malloc`, `free`, `__cxa_*`, ...). Emscripten's runtime provides `emscripten_*`, `__syscall_*`, `fd_write`
   and its libc under other names, so an unmodified Emscripten runtime fails at instantiation with a LinkError for each
   missing name. The programs in `tests/wasm` import only the host's stubs.
6. **Exports the glue calls.** Not exported: `__wasm_call_ctors` (the static constructors), `malloc`/`free` (the glue's
   `_malloc`, `allocate`), and the stack functions the glue uses (`emscripten_stack_get_current` and the other
   `emscripten_stack_*` functions for `stackSave`). The `main` export is there; the glue calls it with the argument
   list of the JS host.
7. **Memory growth.** The heap has no room at the start (point 5 of "The heap base" above), so a `sbrk` that calls
   `emscripten_resize_heap` (an import, not provided) would fail on the first allocation.
8. **Stack checks.** The module has no stack limits (`__set_stack_limits`, the stack-overflow checks of the glue).

The glue expectations above come from the Emscripten runtime as it is generally documented; no Emscripten checkout or
`emcc` was available for this step, so they are a list to check in step 2, not a run.

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
