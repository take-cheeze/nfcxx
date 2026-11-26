# Squirrel 3.2 bytecode producer for Path B

Status: the stream reader covers the whole 3.2 stream format. The lowering covers a subset of opcodes (below); everything
else is refused by name. Reference: Squirrel 3.2 stable at f9267f2 (`SQUIRREL_VERSION_NUMBER 320`), built out of tree from a
read-only clone.

Files: `tools/squirrelbc/` (`sq_chunk.{hpp,cpp}` the reader, `sq_dump.cpp` the dump tool, `sq_lower.{hpp,cpp}` the producer,
`sq_lower_main.cpp`), `tests/squirrelbc/` (the suites, `oracle/sqref.c`, `runtime/`).

## 1. Pipeline position

```
sq -c (default options)  ->  tools/squirrelbc: load (sq_chunk) -> lower_module (sq_lower)
   -> IR text, (producer "squirrel-3.2")  -> scripts/mrb.rb scripts/pathb-qbe-emit.rb  -> build/qbe/qbe
   -> link with tests/squirrelbc/runtime (sqbcrt.c, driver.c)
```

The producer follows docs/notes/pathb-stage2.md section 1: it decodes an image and emits the IR. The IR gains no Squirrel
forms. Squirrel's value representation, its errors and its calls stay in the producer and reach the runtime through
`(call ...)`: `sqbc_rt_arith`, `sqbc_rt_neg`, `sqbc_rt_compare`.

## 2. The stream (what the reader checks)

Layout as `sq_writeclosure` writes it (`squirrel/sqapi.cpp`, `squirrel/sqobject.cpp`), integers in the writer's native order:

- `u16` tag 0xFAFA; `u32` HEAD; `u32` sizes of SQChar, SQInteger, SQFloat. The reader takes SQChar 1, SQInteger 8,
  SQFloat 4 or 8, and refuses any other size.
- Prototype (recursive): PART, source object, name object, PART, eight `i64` counts (literals, parameters, outers, local
  infos, line infos, default parameters, instructions, nested prototypes), PART, literals, PART, parameters, PART,
  outers (`u64` type, src, name), PART, local infos (name, `u64` pos, start, end), PART, line infos (2 x `i64`), PART,
  default parameters, PART, instructions (8 bytes each: `i32` arg1, then op, arg0, arg2, arg3), PART, nested prototypes,
  then `i64` stacksize, `u8` bgenerator, `i64` varparams.
- An object is a `u32` type word (`sq_type`, the flag bits included) and a payload: strings as `i64` length and bytes,
  integers and booleans as `i64`, floats at SQFloat width, null empty.
- Then TAIL, then end of file. Any byte after TAIL, a truncated record, a count larger than the rest of the stream, or a
  tag mismatch is refused.

There is no version field. The 3.2 identity is the tags, the record order and the opcode enum (sqopcodes.h, 61 opcodes,
0x00 to 0x3C). `sq_dump --opcodes` is checked against that enum by the reader suite.

## 3. The lowering

A prototype becomes `sq_fn_N(SQV *ret, SQV *base)`. A register R is `base + 16*R`. An SQV is 16 bytes: the object type
word at offset 0 (`unsigned_int`, sqobject.h's OT_NULL 0x01000001, OT_INTEGER 0x05000002, OT_BOOL 0x01000008) and the
payload at offset 8 (`long`). A null has payload 0 and a boolean 0 or 1, so Squirrel's IsFalse is "payload == 0" on
every value in the subset.

Each instruction starts at a label `pcN`. Integer fast paths are inline IR (`wadd`, `lt.s`, `le.s`), with the operands
checked by tag. Anything else calls a helper, which performs the whole operation or raises the reference's error.

| Opcode(s) | Lowering |
| --- | --- |
| LINE | nothing (no debug hook) |
| LOAD (int, bool, null literal), LOADINT, LOADBOOL, LOADNULLS, DLOAD | store of the immediate |
| LOAD of a string literal, DLOAD of strings | `sqbc_rt_loadstr` into the register; the text is a `(data)` item of the module, interned by the runtime |
| LOAD of a float literal, LOADFLOAT | store of the float: tag OT_FLOAT (0x05000004), payload the 4 bytes of the float (low 32 bits) |
| MOVE, DMOVE | copy of the 16 bytes, in the instruction's order |
| ADD, SUB, MUL | int inline (`wadd`, `wsub`, `wmul`); else `sqbc_rt_arith` (floats and mixed int/float there) |
| DIV, MOD | `sqbc_rt_arith` |
| NEG | `sqbc_rt_neg` |
| NOT | int, bool or null: payload == 0; a float: `sqbc_rt_float_zero` (IsFalse) |
| CMP with >, >=, <, <= | int inline (`lt.s` with the operands swapped for >, >=); else `sqbc_rt_compare` (floats, mixed int/float) |
| CMP with 3-way (<=>) | refused |
| EQ, NE | same tag and same payload, for a non-float; a float, or two different tags, through `sqbc_rt_equal` (IsEqual); the literal form (arg3 != 0) is loaded into the scratch value first, so a string literal is interned |
| JZ, AND, OR | the truth of the value as NOT (a float through `sqbc_rt_float_zero`) |
| GET, GETK | `sqbc_rt_get` into a scratch value, then the register. selfidx 0 (register 0) falls back to the root table |
| PREPCALL, PREPCALLK | the callee by `sqbc_rt_get` into arg0; the receiver (arg2) copied into arg3 (sqvm.cpp order) |
| SET, NEWSLOT | `sqbc_rt_set` / `sqbc_rt_newslot`; the value copied to arg0 when arg0 is a register |
| NEWOBJ (a table, an array) | `sqbc_rt_newtable`, or `sqbc_rt_newarray` with arg1 as the reserve (NOT_ARRAY) |
| NEWOBJ of a class (NOT_CLASS) | `sqbc_rt_newclass` into arg0, with the base register arg1 (NULL when arg1 is -1); arg2 must be 0xFF (no attributes), else refused |
| GETBASE | `sqbc_rt_getbase` into arg0: the class the running closure's class extends, or null (the running closure is the third parameter) |
| NEWSLOTA | `sqbc_rt_newslota` (a class member; bit 1 of arg0 is the static flag); bit 0 (attributes) is refused |
| APPENDARRAY | `sqbc_rt_append` of the value of arg2 (AAT_STACK a register, AAT_LITERAL a literal, AAT_INT arg1, AAT_BOOL arg1, AAT_FLOAT the float whose bits are arg1) |
| CALL, TAILCALL | `sqbc_rt_call(callee, ret, frame, nargs)`: the frame starts at the `this` register (arg2); see section 4. TAILCALL is the same call: the compiler follows it with the RETURN of its target |
| CLOSURE | `sqbc_rt_closure` with the prototype's index, its parameters, frame size and outer count; a bound register (arg2) is the environment; each outer is bound by `sqbc_rt_outer_local` (a register of this frame: a local of the enclosing function) or `sqbc_rt_outer_outer` (an outer of the running closure) |
| GETOUTER, SETOUTER | `sqbc_rt_getouter` / `sqbc_rt_setouter` on the running closure (the third parameter of `sq_fn_N`) |
| CLOSE | `sqbc_rt_close` on the register arg1: the outers of the stack from there on move into their objects |
| AND, OR | copy of the operand and jump when it decides the result |
| JMP, JZ | goto; JZ jumps when payload == 0 |
| JCMP | the fused CMP and JZ of the compiler's peephole: jump when the comparison is false |
| RETURN | copy of the register (or null) into `*ret`, then `(return)` |
| everything else (LOADROOT, INSTANCEOF, BITW, INC, FOREACH, ...) | refused: `refused: _OP_NAME is not lowered yet (pc N)`, exit 3 |

A nested function with default parameters or a vararg is refused by name (the main prototype is always vararg, with
`vargv` unused, and is lowered either way).

Each module gets one `sq_fn_N(ret, base, clo)` per prototype (pre-order, main is 0; `clo` is the running closure, NULL for
main) and a dispatcher `sq_dispatch(fn, ret, frame, clo)`, an IR function with one test per prototype, which the runtime
calls for a closure. A string literal is a `(data)` item (`sqs_N`), one per distinct text.

The helper's messages are the reference's (sqvm.cpp, sqdebug.cpp): `division by zero`, `arith op + on between 'integer'
and 'null'`, `attempt to negate a bool`, `comparison between '1' and 'bool'`. The runtime prints `error: MESSAGE` and
exits 1, as `sqref` does.

## 4. Reference behaviour kept by the runtime

- `%` (`_OP_MOD`) calls ARITH_OP and drops its result. A zero divisor or a non-integer operand records the message
  (Raise_Error only stores it) and execution goes on with the target unchanged. `sqbc_rt_arith` does the same. `/` and
  the other arithmetic raise and stop the script (`_ARITH_NOZERO` and `_GUARD`). The test `lower/mod_zero.nut` pins this.
- Integer comparison of bools and nulls follows ObjCmp: null is less than any other value; two bools compare by their raw
  values; any other mix raises `comparison between`.
- Strings are interned by the runtime (`tests/squirrelbc/runtime/sqbcrt.c`), as the reference interns them: two equal
  strings are the same object, so EQ and NE are the raw compare of the IR. `+` with a string operand concatenates both
  sides through ToString (null, a boolean, an integer; a table or a function is refused at runtime). `< <= > >=` on two
  strings compare the bytes, a proper prefix first.
- Base library and delegates (sqbaselib.cpp). The root table holds `print` (sqbc_rt_init). `print(v)` writes the text of `v`
  through the print function with no newline of its own: base_print asks for `"%s"` only, and the standalone `sq` prints
  the same way (`print(1)` then `print(null)` gives `1null`). The oracle `sqref` sets the same print function. `print` takes
  exactly one value: any other count is `wrong number of parameters` (CallNative, no counts in the text). `tostring` is the
  default delegate's method of an integer, a boolean, a string, an array or a table (`x.tostring()`). The reference has no
  `tostring` for null: `null.tostring()` is `the index 'tostring' does not exist`. A global `tostring(v)` is the root
  table's table delegate, so it passes two values and is `wrong number of parameters`. `len` is the string's and the
  array's, and takes no argument.
- Arrays (sqarray.cpp, sqvm.cpp Get and Set). A GET or SET with an integer index out of range (a negative index is out of
  range) is `the index 'K' does not exist` at once, with no fallback to the root table. A SET with a key that is not an
  integer is `indexing array with T`. A GET with a string key that is not a method is `the index 'K' does not exist`; an
  array method that is not lowered (extend, insert, sort, map, ...) is `unsupported array method` at run time, where the
  reference runs it. `append` and `push` (the result is the array), `pop` (`empty array` on an empty one), `reverse` (the
  array), `slice` (`wrong indexes`, `slice out of range`; a null or non-number start or end is `parameter N has an invalid
  type 'T' ; expected: 'integer|float'`) and `find` (the index, or null) are lowered, as are the argument counts of each
  (`wrong number of parameters`). Arrays compare by identity for `==`; `<` on two arrays compares their addresses, as the reference does, and is
  not tested.
- Floats (sqvm.cpp, sqobject.h). SQFloat is the 4-byte `float` of this build (no SQUSEDOUBLE): a float value is its
  4 bytes in the payload's low 32 bits. Arithmetic on a float, or on an integer and a float, is done in float (an integer
  converts to float first, `tofloat`); `/` gives inf or nan for a zero divisor, and `%` is `fmod` of the two as doubles,
  stored as a float. `print`, `tostring` and the concatenation with a string print a float with `%g` (ToString, sqvm.cpp);
  a comparison or equality error prints it with `%.14g` (PrintObjVal). Equal floats compare as 0 in ObjCmp, so `<`,
  `<=`, `>`, `>=` agree with the reference for every value the subset makes (no NaN is tested). `IsFalse` is true for
  +0.0 and -0.0. A float is equal to an integer of the same value (IsEqual compares as floats). The oracle and the driver
  print a float result with `%g`.
- Strings, tables and closures are all payloads that are never 0, so `IsFalse` is still "payload == 0" (sqvm.cpp's
  IsFalse tests the integer of the object, which is non-zero for a pointer). A float is the one exception: see above.
- Number methods (sqbaselib.cpp `_number_default_delegate_funcz`, which a boolean takes too): `tostring`, `tofloat`,
  `tointeger` and `tochar` are lowered. `tointeger` of a float truncates; `tochar` is the one byte `(SQChar)tointeger`, a
  string of length 1 (a byte of 128 or more is negative when indexed, as the reference's char is signed). A string's
  `tofloat` and `tointeger` (with an optional base) are lowered: `cannot convert the string` when no number starts the text;
  a text with a `.` or an exponent is a float for `tointeger` too. `tointeger` with a base of 1 is not tested (the C
  library's behaviour there is undefined and the reference reads an uninitialised end pointer).
- A table GET or SET of a key it does not have is `the index 'K' does not exist` (Raise_IdxError, the key printed as
  PrintObjVal prints it: a string as itself, an integer in decimal, anything else as its type name). A SET on a non-table
  is `trying to set 'T'`, a NEWSLOT on a non-table is `indexing T with K`, a NEWSLOT with a null key is `null cannot be
  used as index`. A GET on a non-table gives the Raise_IdxError text (the reference falls through to it too).
- A string indexed by an integer gives the byte as an integer (signed, as `char` is), a negative index counts from the end.
- Classes (sqvm.cpp CLASS_OP, CreateClassInstance, NewSlot; sqclass.cpp). A class is a list of members: a field (an
  instance value, initialised from the class's default at creation) and a shared member (a method, a static, or any
  closure). The first instance locks the class: then a new non-closure, non-static member is `trying to modify a class
  that has already been instantiated`, and an existing field's default cannot change either. A NEWSLOT of a member whose
  name is a method keeps the method (the reference's table does), so a later field of that name has no effect. A
  `constructor` member is the one a CALL of the class runs, with the instance as `this`; the CALL's target is the instance
  (set before the constructor runs, as sqvm.cpp does), the arguments count `this`, and a class with no constructor ignores
  them. A GET on an instance is its field or a shared member; a SET is only for a field (else the index error, after the
  root fallback when the instance is register 0); NEWSLOT on an instance is `class instances do not support the new slot
  operator`; a SET or NEWSLOT on a class is `trying to set 'class'` and, for NEWSLOT, the class rules above. An instance
  and a class compare by identity, and an arithmetic or comparison error names them as `instance` and `class`. The
  delegate methods of an instance (`getclass`, `rawget`, `rawset`, `rawin`) and of a class (`rawget`, `rawset`, `rawin`,
  `getbase`, `instance`) are lowered: `rawget` and `rawin` look at the members (fields and shared members) with no
  metamethods (`the index doesn't exist` for a missing key in rawget, the reference's text, where the rawset of a missing
  instance key is `the index 'K' does not exist`); a `rawset` of a class goes through NewSlot and a refused slot (a field of
  a locked class) is silently not done, returning the class; a `rawset` of an instance takes only its fields and returns
  the instance; `null` as a key is `null key`. `instance()` makes an instance with no constructor and locks the class, as
  `CreateInstance` does. The other delegate methods (`weakref`, `getattributes`, `setattributes`, `newmember`,
  `rawnewmember`, and `tostring` of an instance or a class) are `unsupported ... method` at run time (`tostring` of an
  instance or a class is refused: the reference prints an address).
- Inheritance (`extends`, CLASS_OP, SQClass's constructor). A class with a base starts with the base's members, fields
  (with their indices, so an instance's fields are the base's then the new ones) and constructor; a field of the derived
  class with a base member's name replaces the default. The base is locked with the derived class (SQClass::Lock). A
  closure defined in a class with a base is a copy that knows the base, which GETBASE returns; `base.f()` is a GET on the
  base class and a call with the instance as `this` (the compiler's MOVE of register 0). A base that is not a class is
  `trying to inherit from a T`.
- Calls (sqvm.cpp `_OP_CALL`, StartCall, Return): the callee's frame starts at the `this` register (arg2) of the caller,
  so its parameters are the caller's registers above it, and the result is written to the caller's target register (arg0)
  when it has one. `nargs` counts `this`: `wrong number of parameters (N passed, M required)` for a mismatch. A closure
  made without an environment takes the `this` the caller passes; a closure with a bound register takes that table.
- Wrapping: `+ - *` and unary minus wrap, as the reference does on LP64 in practice. `INT64_MIN / -1` is undefined in the
  reference (its fast path has no check), and the runtime wraps. It is not tested.

## 5. Tests

- `tests/squirrelbc/run.sh`: the reader. 98 streams (`corpus/*.nut`, `lower/*.nut` and the synthetic stream of
  `lower/synth.rb`) compile with `sq -c`, load in `sq_dump` (every instruction named, stream consumed), and run through
  `sqref` with the same result as their source. Also: the opcode table against the reference header; a golden dump
  (`reader/ints.dump`); and five malformed streams (truncated, trailing byte, bad tag, SQInteger size 4, corrupt TAIL),
  each refused with exit 1.
- `tests/squirrelbc/lower/run.sh`: the end-to-end suite. 91 programs (`lower/*.nut`: integers, strings, tables, calls,
  closures, print, tostring, arrays, floats, classes and inheritance, number and string conversions, array methods, class
  and instance delegates) match `sqref` on the printed result and the status; 56 runtime errors (`lower/rterr/`) match the message and status 1; 8 programs (`lower/err/`) are refused with exit 3; `lower/synth.rb` writes a stream with DLOAD, DMOVE, LINE and
  LOADNULLS. A string result is printed by `sqref` and by the driver alike (the text, one line).
- The oracle is `tests/squirrelbc/oracle/sqref.c`: the reference VM, built against the reference tree's
  `libsquirrel_static.a`. It loads `.nut` (compile) and `.cnut` (`sq_readclosure`) and prints the result line.

Both scripts need `SQ_BUILD` (a CMake build of the reference tree: `bin/sq`, `lib/libsquirrel_static.a`) and `SQ_SRC` (its
source tree). Without them they exit 77 (skip). The lowering suite also needs `build/qbe/qbe` and ruby.

## 6. Open questions

- The brief says 62 opcodes. The reference header has 61 (0x00 to 0x3C; `_OP_JNZ` is commented out). The reader uses 61.
- The stream has no version field. The reader cannot tell 3.1 from 3.2 by the header, only by the tags and the opcode
  set. It refuses an opcode above 0x3C.
- `sq -c` has no option that turns the peephole optimizer off. DMOVE and DLOAD do not occur in the corpus compiled with
  defaults, so they are tested only through `lower/synth.rb`.
- SQUnsignedInteger (the outer type, the local info positions) is not recorded in the stream. The reader assumes it is
  the same size as SQInteger (8 bytes on LP64).
- Only the LP64 layout is read. A wide SQChar, a 32-bit SQInteger, or a big-endian writer is refused.
- Nothing above is verified against a 32-bit or Windows reference build.
- Still not lowered: an array method other than `len`, `append`, `push`, `pop`, `reverse`, `slice` and `find` (`extend`,
  `insert`, `sort`, `map`, ...), and a string method other than `len`, `tostring`, `tofloat` and `tointeger` (`slice`,
  `find`, `tolower`, `toupper`, `weakref`) are `unsupported ... method` at run time, where the reference runs them; no test.
  A method of the table delegate other than `tostring` (`t.len()`, `t.rawget` ...) is "the index does not exist". A
  float as a table or array key is `float keys are not lowered` at run time (the reference hashes floats; not modelled).
- Objects (strings, tables, closures) are never freed: the runtime is a test harness with no collector, so a long loop
  that builds strings or tables uses memory without a bound.
- A `tostring` of an array, a table or a function (in a concatenation, through `print` or the method) is refused at run
  time: the reference prints an address.
- LOADROOT (the reference's root-table fast path) is refused; the lowering reaches the root through GET on register 0.
- The outer objects are kept as the reference keeps them (an open list by descending stack address, closed by CLOSE and by
  the return of the frame). A closure called after its creating frame has returned reads the closed value.
- Classes: a class or a member with attributes (`</ ... />`) is refused by name. A metamethod of a class (a closure named
  `_add`, `_tostring`, `_inherited`, ... the MM_* names of sqobject.h) is `class metamethods are not lowered` at run time:
  the reference makes it a metamethod, not a member, so the program's output differs; no test (a refusal from the
  producer would not match a program the reference runs).
- TAILCALL is lowered as CALL (the reference reuses the frame of a closure). A tail recursion deep enough to need the frame reuse is a stack overflow here (`stack overflow`, the runtime's own text).
- Not lowered: INSTANCEOF, LOADROOT and DELETE (refused by name); the delegate methods of an instance and a class that
  section 4 does not list.
