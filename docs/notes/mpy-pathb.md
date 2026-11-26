# MicroPython .mpy to Path B IR

Status, 2026-11-25: the `.mpy` reader (`tools/mpy/mpy_reader.{hpp,cpp}`) loads format 6 bytecode modules and decodes every
function's prelude and instructions. The lowering (`tools/mpy/mpy_lower.{hpp,cpp}`) turns a module's top-level code and its functions, including closures
(cell and free variables), into Path B IR, and `tests/mpy/lower/run.sh` checks it against the reference interpreter.
Everything else in the not-yet list below is refused by name.

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
- A pointer (`xx00`, not zero) to a heap object whose first member is a pointer to its type. Heap types: str, function,
  cell, list, tuple and iterator (see Strings, Closures and Containers below).

The runtime is `tests/mpy/runtime/mpy_rt.c`. The in-place operators (`MP_BINARY_OP_INPLACE_*`, codes 9..21) are the
binary operators plus 13, as in `py/runtime0.h`; on ints they give the same result.

## Containers

- A list is a heap record {type, len, cap, items}; a tuple holds its items in place; an iterator names its sequence and
  the next index. The lowering pushes the items on the runtime value stack for `BUILD_LIST`/`BUILD_TUPLE`, as calls do.
- `LOAD_SUBSCR`, `STORE_SUBSCR` and `UNPACK_SEQUENCE` (the first item ends on top, as MicroPython's `mp_unpack_sequence`
  leaves it) go through `mpy_getitem`, `mpy_setitem` and `mpy_unpack_get`. Their error messages are MicroPython's.
- A `for` loop's iterator takes `kIterSlots` (4, the `MP_OBJ_ITER_BUF_NSLOTS` of obj.h on both 32- and 64-bit hosts) stack
  slots, with its object in the bottom one. `GET_ITER_STACK` makes it, `FOR_ITER` reads it there, and `break` pops all four.
  The plain `GET_ITER`, which never feeds a `for` loop, is refused.
- `FOR_ITER` gives 0 when the sequence is exhausted, which is never a value, so the lowering tests for 0.
- repr: a list prints as `[...]`, a tuple as `(...)` with a trailing comma for one item, a str quoted as MicroPython quotes it.
  A top-level str prints raw, as before.

## Lowering (first slice)

`tools/mpy/mpy_lower.cpp` lowers a module's top-level code. The stack becomes slots `stk.N`, one per depth. The depth before
each instruction is computed first, and a join must agree on it. Each instruction gets a label, and jumps go to the
labels of their targets. It covers small-int and None/bool constants, names (`LOAD_NAME`, `STORE_NAME`, `LOAD_GLOBAL`,
`STORE_GLOBAL`), locals (`LOAD_FAST`/`STORE_FAST`), `POP_TOP`, `DUP_TOP`, `ROT_TWO`, the binary and unary operators,
`POP_JUMP_IF_FALSE`/`TRUE`, `JUMP`, the `JUMP_IF_*_OR_POP` pair (short-circuit `or`/`and`), `ROT_THREE` (chained
comparisons), `LOAD_CONST_STRING` and `LOAD_CONST_OBJ` (str constants), `MAKE_FUNCTION`, `LOAD_DEREF`, `STORE_DEREF`,
`MAKE_CLOSURE`, `CALL_FUNCTION`, `BUILD_LIST`/`BUILD_TUPLE`, `LOAD_SUBSCR`/`STORE_SUBSCR`, `UNPACK_SEQUENCE`, `GET_ITER_STACK`
and `FOR_ITER`, and `RETURN_VALUE`. Any other opcode is refused by name and no IR is written.

Each code object is one IR function. The module body is `mpy_module`. A function is `mpy_fn_K(ret, args, nargs)`: it
copies its arguments into its locals `loc.N` and stores its result through `ret`. The IR has no function-address value, so
`mpy_dispatch(K, ret, args, nargs)` routes a call to `mpy_fn_K`, and a function object is a runtime record holding K and the
argument count. A call pushes each argument on the runtime value stack (`mpy_push`), then calls `mpy_call(fn, n)`, which
checks the arity and dispatches. Functions with defaults, keyword arguments or `*args` are refused.

## Closures

MicroPython's layout (`py/compile.c` `compute_scope_locals`, `py/objclosure.c`), which the lowering follows:

- A function's locals are its captured cells first (the free variables), then its parameters, then its other locals,
  and then the cell variables it owns. The prelude's `n_pos_args` counts the free variables too. The prelude's cell list
  names the owned cell variables by local index.
- `MAKE_CLOSURE k` (k is the number of captured cells) pops k cells that `LOAD_FAST` pushed, one per free variable of
  the child, in the parent's order. It makes a function object that holds them.
- `LOAD_DEREF i` and `STORE_DEREF i` read and write the cell in local i. A variable that is not a parameter starts
  unbound, and a read of an unbound cell is a `NameError`.

Representation and calling convention (`tests/mpy/runtime/mpy_rt.c`):

- A cell is `MpyCell { value }`, a heap box. The prologue of a function boxes each owned cell variable (`mpy_make_cell`).
  A parameter keeps its value in the box; any other variable starts at 0.
- A function object is `MpyFunc { index, nargs, n_closed, closed[] }`. `nargs` is the count the caller passes, without
  the captured cells. A closure is the same record with `n_closed` cells, made by `mpy_make_closure(K, nargs, k)`, which
  pops the k cells off the value stack. A plain function has `n_closed` 0.
- The captured cells are passed as the first arguments. `mpy_call` inserts a closure's cells in front of the arguments
  on the value stack, as MicroPython's `closure_call` does, and then calls `mpy_dispatch` with `nargs + n_closed`
  arguments. So `mpy_fn_K` copies all of its arguments, the cells included, into its locals with no special case, and
  `LOAD_DEREF` and `STORE_DEREF` read and write through the cell in the local.

A nested def that has default arguments (`MAKE_CLOSURE_DEFARGS`) and a `del` of a closure variable (`DELETE_DEREF`) are
refused by name.

## Strings

A str value is a pointer to a heap record, `MpyStr` in `tests/mpy/runtime/mpy_rt.c`:

- word 0: the type pointer (the str type), so the runtime can tell a str from a function object;
- word 1: the length in bytes (not characters; the bytes need not be UTF-8);
- then the bytes, followed by a NUL so the text can be passed to C.

The record is malloc'd and immutable, and it is never freed: this slice has no GC. A literal (`LOAD_CONST_STRING`, a qstr;
or a str in the constant table through `LOAD_CONST_OBJ`) is allocated the first time its site runs, through
`mpy_str_lit(bytes, len, id)`. `id` numbers the distinct texts of the module densely, so a site costs one allocation and
later runs reuse it. A loop that builds strings with `+` allocates a record per step and keeps all of them.

Operators on a str (`mpy_binop`): `==` and `!=` compare the bytes, and a str never equals a non-str (so `'1' == 1` is
False, as in the reference). `+` concatenates two strs. A `+` with a non-str operand is a runtime error with the
reference's message (`unsupported types for __add__: 'str', 'int'`; a bool is reported as `'int'`). The ordering operators
and every other operator on a str are a runtime error saying they are not lowered yet. Truth: an empty str is false.
`print` of a str writes its bytes and a newline, with no quotes.

## Checks

- `tests/mpy/reader_run.sh` (needs `MPY_CROSS`): every corpus module in `tests/mpy/corpus` loads and decodes.
- The reader refuses trailing bytes and an instruction that runs past the end of its function, so a passing decode
  consumes every byte.
- `tests/mpy/lower/run.sh` (needs `MPY_CROSS` and `MICROPY`): each `lower/*.py` runs through lowering, emitting, QBE and
  linking, and its printed `result` must equal the reference's `print(m.result)` for the same `.mpy`. Each
  `lower/err/*.py` must be refused with exit 3. Each `lower/rterr/*.py` must fail at run time with exit 1 and the
  exception line that the reference raises for it.

## Not yet

Defaults and keyword arguments (`MAKE_FUNCTION_DEFARGS`, `MAKE_CLOSURE_DEFARGS`), `del` of a closure variable
(`DELETE_DEREF`), generators, containers, str methods and formatting, str ordering and repetition, classes, exceptions,
`is`, big ints, and the rest of the opcodes. A str constant through `LOAD_CONST_OBJ` is lowered, but mpy-cross emits text
literals as qstrs, so no test program reaches that path yet. Nothing is freed: a str lives until the process ends. Also the
`luac`-style opcode oracle is still blocked, and string pattern matching is paused.
still blocked, and string pattern matching is paused.
