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
- `UNPACK_EX` (a star target, `a, *b, c = xs`) is `mpy_unpack_ex`, which makes the values once as `mp_unpack_ex` lays them out
  (a list in stack order, the first value last in the list), and the lowering stores value j at stack slot j from the sequence's
  slot. The star target is a list of the values between. A list or tuple is read in place; any other iterable is read once, and
  its short-sequence message counts the values read (`need more than N values to unpack`), as the reference does.
- A `for` loop's iterator takes `kIterSlots` (4, the `MP_OBJ_ITER_BUF_NSLOTS` of obj.h on both 32- and 64-bit hosts) stack
  slots, with its object in the bottom one. `GET_ITER_STACK` makes it, `FOR_ITER` reads it there, and `break` pops all four.
  The plain `GET_ITER`, which never feeds a `for` loop, is refused.
- `FOR_ITER` gives 0 when the sequence is exhausted, which is never a value, so the lowering tests for 0.
- repr: a list prints as `[...]`, a tuple as `(...)` with a trailing comma for one item, a str quoted as MicroPython quotes it,
  and a range as `range(a, b)` (or `range(a, b, step)` when the step is not 1). A top-level str prints raw, as before.
- `range(...)` (one to three small-int arguments) is a MpyRange {start, stop, step, len}. `GET_ITER` on it makes an iterator
  whose index counts the items given; `len` and truth use `len`. Containment in a range is refused at run time, and so is a
  range as a dict key or in equality.
- `LOAD_METHOD` of `append` or `pop` on a list, or of the dict methods (see Dicts), gives the builtin method, and of an
  instance or class the method of its class (see Classes). A value with no such attribute fails with MicroPython's
  AttributeError. The lowering refuses the builtin method names it does not lower, by name (`kBuiltinMethods` in
  `mpy_lower.cpp`). `CALL_METHOD` passes the self (0
  for none) and the arguments to `mpy_call_method`, so `xs.pop(i)` and `xs.append(x)` take one or two arguments. A keyword
  argument is refused.
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
- A tuple's hash is `mp_obj_tuple_unary_op`'s: the address of MicroPython's empty tuple plus the sum of the items' hashes,
  kept as a 63-bit small int. The reference's address is 16-aligned (`hash(())` is a multiple of 16), so the runtime starts
  from a 16-aligned address too, and tables of up to 16 slots take the same order. Bigger tables depend on that address in
  the reference, and it varies from run to run, so a test does not print one. A tuple key is unhashable when an item is.
- A list, dict, set, view, range or slice is unhashable (`unsupported type for __hash__: 'X'`). A function, class or instance
  hashes by its address.
- Equality of keys (`mp_obj_equal`): the same word, equal strs, equal numbers and bools, and lists or tuples with equal
  items (`obj_equal`). Two different dicts, sets or ranges are not compared yet, so that fails.
- The KeyError text is `KeyError: ` followed by the key as `str` gives it: a str as its text, anything else by repr.
- Operations: `BUILD_MAP n` pushes an empty dict; `STORE_MAP` takes [dict, value, key] (key on top) and leaves the dict.
  A load, a store and `in` go through `mpy_getitem`, `mpy_setitem` and `map_lookup`. `len` and truth count the live items.
- `del d[k]`: `LOAD_NULL` pushes 0, and `STORE_SUBSCR` with 0 deletes (MicroPython 1.29 has no DELETE_SUBSCR: the compiler
  emits LOAD_NULL, ROT_THREE, STORE_SUBSCR). A list item is deleted the same way. A tuple key is hashed and compared as a
  store or a load does (`del d[(3, 4)]` on a missing key is `KeyError: (3, 4)`; an unhashable item is the hash TypeError).
- A dict comprehension stores each item with `STORE_COMP` (kind 1).
- Methods (`LOAD_METHOD`, called by `CALL_METHOD`, with the dict as the self): `get(key[, default])` (None when missing),
  `pop(key[, default])` (a missing key with no default is a KeyError, the value stays in the slot the removal leaves),
  `keys()`, `values()` and `items()` (views, below) and `update([other])` (a dict, or an iterable of two-item lists or
  tuples; a non-iterable is `'X' object isn't iterable`, a pair of another length `ValueError: dict update sequence has
  wrong length`). Their argument-count errors are the reference's (`function missing 1 required positional arguments`,
  `function expected at most 3 arguments, got N`, ...). `copy()` copies the table slot for slot (deleted slots too), `clear()`
  drops the table, `setdefault(k[, v])` hashes k and adds it with v (None), `popitem()` removes and returns the first live slot
  (`KeyError: popitem(): dictionary is empty`), and `fromkeys(iterable[, v])` is the classmethod: `d.fromkeys(...)` is called with
  no self, and its table is sized by the iterable's length. Iterating a str is lowered (see Strings), so `fromkeys` takes a str. The
  lowering does not refuse `copy`, `clear`, `setdefault`, `popitem` or `fromkeys` by name, since the receiver's type is not
  known there: on a list, str or other value that is not a dict the runtime fails at run time ("a method copy of a 'list' is
  not lowered yet"). Read as a value (`f = d.get`) a dict method fails at run time.
- A view is {type, dict, kind}, live: it reads the dict's table. `repr` is `dict_keys([...])`, `dict_values([...])` or
  `dict_items([(k, v), ...])`, in table order. `len`, truth, `in` (a key, a value by equality, a (key, value) pair) and
  iteration are lowered. A view has no hash and no equality (`==` fails here; the reference compares identities).
- Iteration (`for`, `GET_ITER_STACK`) of a dict, a set or a view is the table in order from the next slot. The reference
  raises if the dict changes size during the loop; this does not check, so a loop that inserts is not matched.

## Sets

- A set is an `MpyDict` record with type `mpy_type_set` and no values, so the table, the probing and the growth are the map's.
  The lookup differs from a dict's in one way, which `map_lookup` follows: a set always compares with `mp_obj_equal` (no
  qstr shortcut). `BUILD_SET n` makes a set with n slots (`mp_obj_new_set(n, items)`) and adds the items in order.
- A set comprehension stores each item with `STORE_COMP` (kind 2) into the set its code builds before the loop.
- Operations: `in` (a lookup, which answers without hashing for an empty set, as `mp_set_lookup` does), `len`, truth, `for`,
  and the repr: `{a, b}` in table order, and `set()` when empty. Its hash is refused (a set is unhashable).
- Methods (`LOAD_METHOD`, called by `CALL_METHOD`): `add(x)`, `discard(x)`, `remove(x)` (a missing item is `KeyError` with the
  item), and `union(other)`, `intersection(other)` and `difference(*others)`, whose argument may be any iterable, as objset.c
  takes it. Also `pop()` (the first item in table order, removed; an empty set is `KeyError: pop from an empty set`),
  `update(*others)`, `difference_update(*others)`, `intersection_update(other)`, `symmetric_difference(other)`,
  `symmetric_difference_update(other)`, `issubset(other)`, `issuperset(other)` and `isdisjoint(other)`. Each argument may be any
  iterable; `issubset` and `issuperset` make a set of a non-set argument first, so an unhashable item is the hash TypeError.
  The argument counts and the TypeErrors are the reference's. A set method not listed (`copy`, `clear`, ...) fails at run
  time, as "not lowered yet" (`kBuiltinMethods` refuses the names only the set and list have).
- Operators: `|`, `&` and `-` on two sets build a new set (`|` is a copy of the left set with the right's items added; `&` is a
  new set of the items of the right that are in the left, in the right's order; `-` removes the right's items from a copy).
  `^` is the symmetric difference: a copy of the left set with each item of the right added when it is not there and removed
  when it is (`MAP_TOGGLE` in `map_lookup`, which is `ADD_IF_NOT_FOUND_OR_REMOVE_IF_FOUND`). The in-place `|=`, `&=`, `-=` and
  `^=` change the left set (`s -= s` clears it). The comparisons are on two sets: `<` and `>` are the proper subset and
  superset (the used counts must differ), `<=` and `>=` the subset and superset, and `==` and `!=` compare the items. With a
  non-set operand, `==` and `!=` are identity (False and True), and the other operators are a TypeError that names the
  operator without the in-place prefix (`unsupported types for __xor__: 'set', 'list'`), as the reference does. Two different
  sets are equal by their items wherever `obj_equal` compares values (`in` on a list, and the items of tuples and lists).

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
  A str is indexed and sliced by character, so `s[i]` is a one-character str. Iterating a str (`for c in s`, GET_ITER_STACK
and FOR_ITER, and `dict.fromkeys(s)`) gives one-character strs, one per UTF-8 character. A tuple or str store or delete is `'tuple'
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
`MAKE_CLOSURE`, `CALL_FUNCTION`, `BUILD_LIST`/`BUILD_TUPLE`/`BUILD_SET`, `LOAD_SUBSCR`/`STORE_SUBSCR`, `BUILD_MAP`/`STORE_MAP`, `BUILD_SLICE`, `LOAD_NULL` (for `del`), `STORE_COMP` (list, dict and set
comprehensions), `UNPACK_SEQUENCE`, `UNPACK_EX`, `GET_ITER_STACK`
and `FOR_ITER`, and `RETURN_VALUE`, and the exception and class opcodes (see Exceptions and Classes): `SETUP_EXCEPT`,
`SETUP_FINALLY`, `SETUP_WITH`, `WITH_CLEANUP`, `POP_EXCEPT_JUMP`, `END_FINALLY`, `UNWIND_JUMP`, `RAISE_OBJ`, `RAISE_LAST`, `LOAD_BUILD_CLASS`, `LOAD_ATTR`,
`STORE_ATTR`, `LOAD_METHOD`/`CALL_METHOD`, `DELETE_FAST`, `DELETE_NAME`, `DELETE_DEREF`, `DUP_TOP_TWO`, with `LOAD_NAME`/`STORE_NAME` for the
class namespace and `LOAD_GLOBAL`/`STORE_GLOBAL` for the globals. Any other opcode is refused by name and no IR is written.

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

A nested def that has default arguments (`MAKE_CLOSURE_DEFARGS`) is refused by name. A `del` of a cell or free variable
(`DELETE_DEREF`) stores 0 in the cell, which is unbound, so a read of it is `NameError: local variable referenced before
assignment` (the reference's text).

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

## Exceptions

MicroPython's exception stack (`py/vm.c`: SETUP_EXCEPT, SETUP_FINALLY, POP_EXCEPT_JUMP, END_FINALLY, UNWIND_JUMP, RAISE_OBJ,
RAISE_LAST), as the lowering follows it:

- A try block is a heap record `MpyBlock` {jmp_buf, the previous block, the value-stack height, the namespace depth, landed,
  exc}, pushed on a block stack by `mpy_try_enter`. The lowered code calls `_setjmp` on it in its own frame. A raise
  (`raise_value`) takes the innermost block that is not already running its handler, restores the value stack and the
  namespace depth it saved, and `longjmp`s to it. The landing (a stub after the body) gives the exception to the handler at
  the target, in the slot of the try's depth (the handler is entered one deeper than the try, as in the bytecode).
- A landed block stays on the stack until its handler ends (POP_EXCEPT_JUMP, END_FINALLY pops it), as MicroPython keeps its
  exception block. An exception raised by a handler therefore skips its own block. A bare `raise` re-raises the exception of
  the innermost landed block (`mpy_reraise`).
- `except C:` is the binary operator EXCEPTION_MATCH (8): C is a builtin exception class, a user class derived from one, or a
  tuple of those. `as` binds the exception; the SETUP_FINALLY that wraps the handler body deletes the name at its end
  (DELETE_FAST, or DELETE_NAME at module level), and an END_FINALLY with an exception on top raises it again.
- Exception classes are builtin records (`BI_EXC + k`): BaseException, Exception, ArithmeticError, LookupError,
  ZeroDivisionError, IndexError, KeyError, ValueError, TypeError, AttributeError, NameError, RuntimeError and
  NotImplementedError, with MicroPython's bases. An instance is a `MpyInst` whose arg is its one argument (0 for none).
  `str(e)` is the argument as `str` gives it; the uncaught line is `Name: text`, as the reference prints it.
- The runtime's `fail()` messages that begin with an exception class name ("KeyError: ...", "IndexError: ...") raise that
  class, so a try catches the runtime's own errors. Any other message is fatal, as before.
- A break or continue out of a try (UNWIND_JUMP) pops the blocks it leaves (its count is the low 7 bits of the extra byte;
  bit 0x80 is a break out of a for loop, which drops the iterator's slots in the depth). Leaving a finally runs its body
  (see Unwinding through finally below).
- Leaving a with block (a break, a continue or a return out of its body) calls its `__exit__(None, None, None)` as WITH_CLEANUP's
  normal path does, innermost block first. The block is dropped before the exit is called, so an exception from the exit goes to
  the blocks around the statement (the reference may differ there; this is not checked). The walk records each with block with
  its exit method's stack slot, and each for loop as an entry (kind 3) with its iterator's base slot, so a break that the
  compiler emits as an UNWIND_JUMP (0x80) finds the slot the stack is cut back to. A break with no block to leave is four
  POP_TOPs and a JUMP, as mp_emit_bc_unwind_jump emits it; the JUMP at the loop's base ends the loop's entry.
- A return (RETURN_VALUE) leaves every block it is in, as MicroPython's unwind_return does, the with blocks included.
  Before this, a return left its block on the runtime's block stack, so a later raise could longjmp into the returned frame.

Unwinding through finally (a return, a break or a continue that leaves a `try ... finally`). The VM runs the finally body as
a coroutine (vm.c's unwind_jump and END_FINALLY), and the lowering does the same:

- Which finally blocks run is the VM's test, `handler >= ip`: a block whose handler is ahead of the site is run, and a block
  whose handler is behind it (the site is in that handler's body) is only dropped. The walk names a finally block by its SETUP's
  offset (`setup_of`), so the handler is known; the handler's offset is behind the site exactly when the site is in its body.
- A run block stays open. The unwind calls `mpy_block_land` (the block is marked as running its handler, so a raise in the body
  goes past it), stores a pending code in the handler's exception slot (`small_word` of a code unique to the site and the
  block), and jumps to the handler. The handler's END_FINALLY calls `mpy_end_finally`, which pops the block and returns for a
  small int, and then compares the slot with each pending code of that block and jumps to its continuation. The continuation
  goes on with the blocks the unwind has left (with blocks call their exit, as above), and ends in the target or a return.
- A return's value is kept in a slot of its own (`rv.<offset>`) while a finally body runs, since that body reuses the stack
  slots from its own depth up.
- A break out of a finally body in a loop over a range is refused by name. A range loop has no iterator on the stack, so the
  compiler sends the break with no loop-drop bit, and the reference leaves the finally's pending value on the stack at the
  loop's end, one deeper than the normal exit (its POP_TOP pops that value and the loop's counter stays). A static depth cannot
  hold both, so the join is refused (err/finally_range_break.py). The same break in a loop over an iterator (the 0x80 bit) is
  lowered, and so is a break from a try body in a range loop.
- `raise X from Y` (RAISE_FROM) is lowered as `mpy_raise_from`. MicroPython 1.29 does not set a cause: with a cause that is not
  None, it prints `Warning: exception chaining not supported` on stderr (`mp_warning`) and raises X, so the lowering does the
  same and the cause is dropped. `from None` prints nothing. The uncaught line is `Name: text`, as for `raise X`.
- A with statement (`SETUP_WITH`, `WITH_CLEANUP`, `mpy_with_exit`, `mpy_with_enter`, `mpy_with_cleanup`): SETUP_WITH looks up
  `__exit__` and calls `__enter__` before its block is set up (so an exception from `__enter__` is not caught by it), and
  leaves [exit, context manager, as-value] on the stack. The block is kind 2, a handler entered with [exit, manager, exception].
  The normal path is body, LOAD_CONST_NONE, WITH_CLEANUP, END_FINALLY; the exception path lands on WITH_CLEANUP. WITH_CLEANUP
  calls __exit__(None, None, None) for the normal path, and __exit__(class, exception, None) for the other. A true result
  suppresses the exception (END_FINALLY then continues), else END_FINALLY raises it again.

## Classes

- `LOAD_BUILD_CLASS` is the builtin `__build_class__`. It runs the class body (a function) with a fresh namespace dict pushed
  on the namespace stack, then makes the class (a `MpyClass`: its `MpyType info`, which is also the type of its instances,
  its base, and its namespace dict). The body's LOAD_NAME and STORE_NAME go to the namespace on top of that stack; LOAD_GLOBAL
  and STORE_GLOBAL (a function's names) always go to the globals, so a method never sees the class's names. A class base must
  be a class or a builtin exception class.
- An instance is a `MpyInst` {type, dict, arg}. Its attributes are in the dict, keyed by interned name strs (so a dict
  finds them by pointer). `obj.name` (LOAD_ATTR) looks in the instance, then its class and bases; a function found there is
  bound (`MpyBound`). `obj.name = v` (STORE_ATTR) stores in the instance (or in a class).
- `obj.name(args)` is LOAD_METHOD then CALL_METHOD. LOAD_METHOD leaves the method and the self (0 when the attribute is not a
  function of the class, or is in the instance), and CALL_METHOD calls with the self dropped when it is 0.
- `Cls(args)` makes the instance and runs `__init__` with it, if the class (or a base) has one. Without one, a class that
  derives from an exception takes one argument as the exception's argument; any other class takes none.
- A class body that raises, with the exception caught outside it, is not tested against the reference: the reference keeps
  the class namespace as the module's name scope after that (`x` at module level then reads the class's `x`). This lowering
  restores the module's scope, as CPython does.
- `del obj.name` is LOAD_NULL then STORE_ATTR (no DELETE_ATTR in MicroPython 1.29), so a store of 0 removes the attribute.
- `super()` (MicroPython 1.29's compile.c special case): a method that calls `super()` takes the class's `__class__` cell as a
  free variable. The class body makes that cell (its prelude lists it as an owned cell) and returns it, and `__build_class__`
  sets it to the new class. `super().name(args)` is `LOAD_GLOBAL super`, `LOAD_DEREF __class__`, `LOAD_FAST self`,
  `LOAD_SUPER_METHOD name`, the arguments and `CALL_METHOD`: `LOAD_SUPER_METHOD` writes the method over the super global's slot
  and leaves the self (vm.c). `super()` alone is a call of the builtin `super` with the class and self, and its object's
  attributes and methods are looked up in the bases of the class (`super_attr`): the class itself is not searched. A base
  with no `__init__` gives object's (no argument) or the exception's (its one argument). `super(cls, self)` with self not an
  instance of cls is a `TypeError` with no text, as the reference raises it.
- Attribute names in the lowering that are builtin methods of the other types (`count`, `upper`, `keys`, ...) are refused
  by name: the lowering does not know the receiver's type, so a class's method of such a name is refused too.

## Checks

- `tests/mpy/reader_run.sh` (needs `MPY_CROSS`): every corpus module in `tests/mpy/corpus` loads and decodes.
- The reader refuses trailing bytes and an instruction that runs past the end of its function, so a passing decode
  consumes every byte.
- `tests/mpy/lower/run.sh` (needs `MPY_CROSS` and `MICROPY`): each `lower/*.py` runs through lowering, emitting, QBE and
  linking, and its printed `result` must equal the reference's `print(m.result)` for the same `.mpy`. Each
  `lower/err/*.py` must be refused with exit 3. Each `lower/rterr/*.py` must fail at run time with exit 1 and the
  exception line that the reference raises for it.

## Not yet

Defaults and keyword arguments (`MAKE_FUNCTION_DEFARGS`, `MAKE_CLOSURE_DEFARGS`), generators, str methods and formatting, str
ordering and repetition,
big ints, the set methods `copy` and `clear`, the list methods other than append and pop, subscripts of a range, and the rest
of the opcodes. Equality of two dicts, two ranges or two views, `str` of a list, tuple, set or view, and
containment in a range are refused at run time until their repr and equality are built. Changing a dict's size during a
`for` over it is not checked (see Dicts). Identity of strs: a str built at run time is a new object, but MicroPython interns
short strs, so `'a' + 'b' is 'ab'` is True there and False here. Nothing is freed: a str lives until the process ends. Also
the `luac`-style opcode oracle is still blocked, and string pattern matching is paused. A `break` out of a finally body in a loop
over a range is refused (see Unwinding through finally). A `return` or `break` out of a `with` whose `__exit__` raises is not
matched against the reference.
