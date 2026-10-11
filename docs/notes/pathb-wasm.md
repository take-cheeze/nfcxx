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
(the emitter refuses with TEXT). The suite skips, rather than fails, without node.

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

`tests/wasm/run.sh` compiles each test with the harness (`scripts/setup-pathb.sh`), emits it, validates and runs it under
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
