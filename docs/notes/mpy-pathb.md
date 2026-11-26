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
  cell, list, tuple, iterator, range, dict, slice and builtin (see Strings, Closures, Containers, Dicts, Slices and Builtins
  below). The word 0 is never a value: it is the null that a `del` stores (see Dicts).

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
- repr: a list prints as `[...]`, a tuple as `(...)` with a trailing comma for one item, a str quoted as MicroPython quotes it,
  and a range as `range(a, b)` (or `range(a, b, step)` when the step is not 1). A top-level str prints raw, as before.
- `range(...)` (one to three small-int arguments) is a MpyRange {start, stop, step, len}. `GET_ITER` on it makes an iterator
  whose index counts the items given; `len` and truth use `len`. Containment in a range is refused at run time.
- `LOAD_METHOD` of `append` or `pop` gives the list's builtin method (`mpy_load_method`), and a value of another type fails
  with MicroPython's AttributeError. The lowering refuses every other attribute name by name. `CALL_METHOD` pushes the self
  and the arguments, then calls, so `xs.pop(i)` and `xs.append(x)` take one or two arguments. A keyword argument is refused.
- A constant tuple is one object in the .mpy file (mpy-cross folds it), so `LOAD_CONST_OBJ` builds it on each run from its items.
  The items may be None, the bools, small ints, strs, and tuples of those. An int outside the runtime's 62-bit small range is
  refused, as big ints are.

## Dicts

MicroPython's dict is its `mp_map_t` (py/map.c), and the lowering copies that layout: `print` of a dict lists the items in
table order, which is not insertion order. A `MpyDict` is {type, alloc, used, all_keys_are_qstrs, table}, and a table slot
is {key, value}. An empty slot has key 0; a deleted one has the sentinel key 0x1e, which is never a value.

- Hash (`mp_map_lookup`): a small int or a bool is its value (a negative value wraps, as `mp_uint_t` does); None is 6; a
  str is `qstr_compute_hash` (djb2 with `^`), masked to 16 bits, and 0 becomes 1. The reference build's
  MICROPY_QSTR_BYTES_IN_HASH is 2, which the probes confirm. Probing is linear from `hash % alloc`.
- Growth: an insert that finds no empty or deleted slot rehashes into the next size of `hash_allocation_sizes`, adding the
  live items in table order. A dict literal of n items starts with a table of n slots (`BUILD_MAP n`); `{}` starts with none.
- A lookup (`in`, a load, a delete) on an empty table answers without hashing, and so does a lookup of a non-str key in a
  table whose keys are all interned strs (a str literal of the module is interned, a str built at run time is not). Such a
  key is a KeyError, not a TypeError, as in the reference: `d[[1]]` with `d = {'a': 1}` is `KeyError: [1]`. A store always
  hashes, so `d[[1]] = 2` is `TypeError: unsupported type for __hash__: 'list'`.
- A list, dict or slice is unhashable. A tuple or another kind of key is not lowered yet (it would need the tuple's hash and
  equality).
- The KeyError text is `KeyError: ` followed by the key as `str` gives it: a str as its text, anything else by repr.
- Operations: `BUILD_MAP n` pushes an empty dict; `STORE_MAP` takes [dict, value, key] (key on top) and leaves the dict.
  A load, a store and `in` go through `mpy_getitem`, `mpy_setitem` and `map_lookup`. `len` and truth count the live items.
- `del d[k]`: `LOAD_NULL` pushes 0, and `STORE_SUBSCR` with 0 deletes (MicroPython 1.29 has no DELETE_SUBSCR: the compiler
  emits LOAD_NULL, ROT_THREE, STORE_SUBSCR). A list item is deleted the same way.
- A dict comprehension stores each item with `STORE_COMP` (kind 1).

## Slices

- `BUILD_SLICE n` (2 or 3 items: start, stop and step, with None for a missing bound) makes a slice record. It is consumed by
  the `LOAD_SUBSCR` or `STORE_SUBSCR` that follows it.
- The bounds are those of `mp_obj_slice_indices` and `mp_seq_get_fast_slice_indexes`: a negative bound counts from the end
  and is clamped; a step of 0 is `ValueError: slice step can't be zero`; a bound that is not an int is `can't convert X to
  int`.
- A list takes any step to load. To store or delete, only a step of 1 is lowered; another step is `NotImplementedError`,
  which the reference prints as `NotImplementedError: ` (with the trailing space). The value of a store must be a list or a
  tuple (`object 'int' isn't a tuple or list`); it is copied first, so `xs[1:4] = xs` works.
- A tuple takes a step of 1 only, as does a str (`NotImplementedError: only slices with step=1 (aka None) are supported`).
  A str is indexed and sliced by character, so `s[i]` is a one-character str. A tuple or str store or delete is `'tuple'
  object doesn't support item assignment` (or `deletion`).
- A list comprehension stores each value with `STORE_COMP` (kind 0), the collection being `arg >> 2` slots below the top (the
  offset of `vm.c`'s `sp[-(unum >> 2)]`). MicroPython 1.29 has no `LIST_APPEND` opcode; `STORE_COMP` does that job.

## Builtins

- `LOAD_NAME` and `LOAD_GLOBAL` look the name up in the module globals first, then the builtins: `len`, `str` and `range`.
  Both are the same runtime lookup (`mpy_load_name`), so a global of the same name shadows a builtin.
- `len(x)` for a str (the number of UTF-8 characters: the bytes that do not continue a sequence), a list, a tuple and a range.
  Any other value is a TypeError with MicroPython's message.
- `str(x)` for a small int, a bool, None and a str (a str is the same object). `str()` is the empty str. Other values are
  refused at run time, since their repr is not built yet.
- `range(n)`, `range(a, b)` and `range(a, b, step)`: the arguments are small ints or bools (other types are a TypeError), and a
  zero step is a ValueError.
- Operators: `in` on a str is a substring test; on a list or tuple it is an equality test against each item. Equality is by
  value for strs, numbers and bools, and by identity otherwise; a comparison of two different lists or tuples fails, since
  their equality is not built yet. `not in` is `in` with a `not`, as mpy-cross emits it. `is` compares the word: an immediate
  (None, a bool, a small int) or the same heap object. `is not` is `is` with a `not`.

## Lowering (first slice)

`tools/mpy/mpy_lower.cpp` lowers a module's top-level code. The stack becomes slots `stk.N`, one per depth. The depth before
each instruction is computed first, and a join must agree on it. Each instruction gets a label, and jumps go to the
labels of their targets. It covers small-int and None/bool constants, names (`LOAD_NAME`, `STORE_NAME`, `LOAD_GLOBAL`,
`STORE_GLOBAL`), locals (`LOAD_FAST`/`STORE_FAST`), `POP_TOP`, `DUP_TOP`, `ROT_TWO`, the binary and unary operators,
`POP_JUMP_IF_FALSE`/`TRUE`, `JUMP`, the `JUMP_IF_*_OR_POP` pair (short-circuit `or`/`and`), `ROT_THREE` (chained
comparisons), `LOAD_CONST_STRING` and `LOAD_CONST_OBJ` (str constants), `MAKE_FUNCTION`, `LOAD_DEREF`, `STORE_DEREF`,
`MAKE_CLOSURE`, `CALL_FUNCTION`, `BUILD_LIST`/`BUILD_TUPLE`, `LOAD_SUBSCR`/`STORE_SUBSCR`, `BUILD_MAP`/`STORE_MAP`, `BUILD_SLICE`, `LOAD_NULL` (for `del`), `STORE_COMP` (list and dict
comprehensions), `UNPACK_SEQUENCE`, `GET_ITER_STACK`
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
(`DELETE_DEREF`), generators, str methods and formatting, str ordering and repetition, classes, exceptions, big ints, dict
methods and iterating a dict (`for`, `keys`), a dict key that is a tuple or another kind of object, sets (`BUILD_SET`, the
set comprehension), the list methods other than append and pop, subscripts of a range, and the rest of the opcodes. Equality of two different lists or
tuples (and so `in` on a list of them), containment in a range, `list.pop` and `str` of a list or tuple are refused at
run time until their repr and equality are built. Identity of strs: a str built at run time is a new object, but
MicroPython interns short strs, so `'a' + 'b' is 'ab'` is True there and False here. Nothing is freed: a str lives until the
process ends. Also the `luac`-style opcode oracle is still blocked, and string pattern matching is paused.
