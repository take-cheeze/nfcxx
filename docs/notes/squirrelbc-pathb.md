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
| LOAD of a string or float literal, LOADFLOAT | refused |
| MOVE, DMOVE | copy of the 16 bytes, in the instruction's order |
| ADD, SUB, MUL | int inline (`wadd`, `wsub`, `wmul`); else `sqbc_rt_arith` |
| DIV, MOD | `sqbc_rt_arith` |
| NEG | `sqbc_rt_neg` |
| NOT | int, bool or null: payload == 0 |
| CMP with >, >=, <, <= | int inline (`lt.s` with the operands swapped for >, >=); else `sqbc_rt_compare` |
| CMP with 3-way (<=>) | refused |
| EQ, NE | same tag and same payload, with the literal form (arg3 != 0) |
| AND, OR | copy of the operand and jump when it decides the result |
| JMP, JZ | goto; JZ jumps when payload == 0 |
| JCMP | the fused CMP and JZ of the compiler's peephole: jump when the comparison is false |
| RETURN | copy of the register (or null) into `*ret`, then `(return)` |
| everything else (CALL, PREPCALL, GET, SET, NEWOBJ, CLOSURE, BITW, INC, FOREACH, ...) | refused: `refused: _OP_NAME is not lowered yet (pc N)`, exit 3 |

The helper's messages are the reference's (sqvm.cpp, sqdebug.cpp): `division by zero`, `arith op + on between 'integer'
and 'null'`, `attempt to negate a bool`, `comparison between '1' and 'bool'`. The runtime prints `error: MESSAGE` and
exits 1, as `sqref` does.

## 4. Reference behaviour kept by the runtime

- `%` (`_OP_MOD`) calls ARITH_OP and drops its result. A zero divisor or a non-integer operand records the message
  (Raise_Error only stores it) and execution goes on with the target unchanged. `sqbc_rt_arith` does the same. `/` and
  the other arithmetic raise and stop the script (`_ARITH_NOZERO` and `_GUARD`). The test `lower/mod_zero.nut` pins this.
- Integer comparison of bools and nulls follows ObjCmp: null is less than any other value; two bools compare by their raw
  values; any other mix raises `comparison between`.
- Wrapping: `+ - *` and unary minus wrap, as the reference does on LP64 in practice. `INT64_MIN / -1` is undefined in the
  reference (its fast path has no check), and the runtime wraps. It is not tested.

## 5. Tests

- `tests/squirrelbc/run.sh`: the reader. 40 programs (`corpus/*.nut` and `lower/*.nut`) compile with `sq -c`, load in
  `sq_dump` (every instruction named, stream consumed), and run through `sqref` with the same result as their source.
  Also: the synthetic stream of `lower/synth.rb` loads (41 streams in all); the opcode table against the reference
  header; a golden dump (`reader/ints.dump`); and five malformed streams (truncated, trailing byte, bad tag, SQInteger
  size 4, corrupt TAIL), each refused with exit 1.
- `tests/squirrelbc/lower/run.sh`: the end-to-end suite. 28 programs (`lower/*.nut`) match `sqref` on the printed result
  and the status; 5 runtime errors (`lower/rterr/`) match the message and status 1; 11 programs (`lower/err/`) are refused
  with exit 3; `lower/synth.rb` writes a stream with DLOAD, DMOVE, LINE and LOADNULLS.
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
