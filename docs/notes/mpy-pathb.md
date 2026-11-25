# MicroPython .mpy to Path B IR

Status, 2026-11-25: the `.mpy` reader (`tools/mpy/mpy_reader.{hpp,cpp}`) loads format 6 bytecode modules and decodes every
function's prelude and instructions. The first lowering slice (`tools/mpy/mpy_lower.{hpp,cpp}`) turns a module's top-level
code into Path B IR, and `tests/mpy/lower/run.sh` checks it against the reference interpreter. Functions and everything
else in the not-yet list below are refused by name.

## Reference

- Source: `micropython/micropython` v1.29.0 (commit `0fd6c57`), cloned under `build/mp-src` (gitignored).
- Reference interpreter: `build/mp-src/ports/unix/build-standard/micropython`. A `.mpy` file is run by `import`, since
  the Unix port does not take a `.mpy` on the command line.
- Compiler: `build/mp-src/mpy-cross/build/mpy-cross`.

## Format (v6, bytecode only)

- Header: `M`, version 6, a flags byte (the arch bits must be 0), and the small-int bit count.
- Then the qstr table and the constant table. A qstr with an odd length is a static qstr: its value indexes the built-in
  table, generated into `tools/mpy/mpy_qstrs_static.inc` from `genhdr/qstrdefs.generated.h`. Bytecode operands index the
  module's qstr table.
- Then the raw code tree. Each function is a varint `kind | children << 2 | length << 3`, the data, and its children.
- A function's data: the prelude (signature and size varints), then `n_info` bytes of code info (the source qstr, the
  argument names, the line table), then `n_cell` cell indices, then the bytecode.

## Bytecode

`tools/mpy/mpy_opcodes.inc` names the opcodes from `py/bc0.h`. The packed opcodes carry their operand in the opcode
byte: `LOAD_CONST_SMALL_INT_MULTI` (0x70..0xaf), `LOAD_FAST_MULTI` (0xb0), `STORE_FAST_MULTI` (0xc0), `UNARY_OP_MULTI`
(0xd0..0xd6) and `BINARY_OP_MULTI` (0xd7 and up).

## Values

One 64-bit word per value, with the tagging of `MICROPY_OBJ_REPR_A` (the default in `py/obj.h`):

- `xxx1` is a small int, the value in the bits above the tag. The range is the reference's small-int range, 62 bits
  signed on 64-bit hosts. A wider result is an error until big ints exist.
- `x110` is an immediate: None `0x06`, False `0x0e`, True `0x16`.
- A pointer (`xx00`) to a heap object whose first member is its type. Heap objects are not in the first slice.

The runtime is `tests/mpy/runtime/mpy_rt.c`. The in-place operators (`MP_BINARY_OP_INPLACE_*`, codes 9..21) are the
binary operators plus 13, as in `py/runtime0.h`; on ints they give the same result.

## Lowering (first slice)

`tools/mpy/mpy_lower.cpp` lowers a module's top-level code. The stack becomes slots `stk.N`, one per depth. The depth before
each instruction is computed first, and a join must agree on it. Each instruction gets a label, and jumps go to the
labels of their targets. It covers small-int and None/bool constants, names (`LOAD_NAME`, `STORE_NAME`, `LOAD_GLOBAL`,
`STORE_GLOBAL`), locals (`LOAD_FAST`/`STORE_FAST`), `POP_TOP`, `DUP_TOP`, `ROT_TWO`, the binary and unary operators,
`POP_JUMP_IF_FALSE`/`TRUE`, `JUMP`, `MAKE_FUNCTION`, `CALL_FUNCTION` and `RETURN_VALUE`. Any other opcode is refused by
name and no IR is written.

Each code object is one IR function. The module body is `mpy_module`. A function is `mpy_fn_K(ret, args, nargs)`: it
copies its arguments into its locals `loc.N` and stores its result through `ret`. The IR has no function-address value, so
`mpy_dispatch(K, ret, args, nargs)` routes a call to `mpy_fn_K`, and a function object is a runtime record holding K and the
argument count. A call pushes each argument on the runtime value stack (`mpy_push`), then calls `mpy_call(fn, n)`, which
checks the arity and dispatches. Functions with defaults, keyword arguments, closures or `*args` are refused.

## Checks

- `tests/mpy/reader_run.sh` (needs `MPY_CROSS`): every corpus module in `tests/mpy/corpus` loads and decodes.
- The reader refuses trailing bytes and an instruction that runs past the end of its function, so a passing decode
  consumes every byte.
- `tests/mpy/lower/run.sh` (needs `MPY_CROSS` and `MICROPY`): each `lower/*.py` runs through lowering, emitting, QBE and
  linking, and its printed `result` must equal the reference's `print(m.result)` for the same `.mpy`. Each
  `lower/err/*.py` must be refused with exit 3.

## Not yet

Closures (cells), defaults and keyword arguments, containers, strings, classes, exceptions, `or`/`and` short-circuits
(`JUMP_IF_*_OR_POP`), chained comparisons, big ints, and the rest of the opcodes. Also the `luac`-style opcode oracle is
still blocked, and string pattern matching is paused.
