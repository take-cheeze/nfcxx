# MicroPython .mpy to Path B IR

Status, 2026-11-25: the `.mpy` reader (`tools/mpy/mpy_reader.{hpp,cpp}`) loads format 6 bytecode modules and decodes every
function's prelude and instructions. Lowering to the Path B IR is not started.

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

## Checks

- `tests/mpy/reader_run.sh` (needs `MPY_CROSS`): every corpus module in `tests/mpy/corpus` loads and decodes.
- The reader refuses trailing bytes and an instruction that runs past the end of its function, so a passing decode
  consumes every byte.

## Not yet

Lowering the bytecode to the Path B IR, a runtime for MicroPython values, and comparison against the reference
interpreter. The stack-based bytecode becomes IR slots after a stack-depth pass, as the Lua lowering does with registers.
