# Lua 5.4 bytecode to Path B IR

Status, 2026-11-24: numbers, comparisons, numeric loops, calls and closures without upvalues lower and run; 19 programs match
Lua 5.4.9. Tables, strings, upvalues, varargs, generic loops and error paths are not lowered yet. The producer rule for this IR is in `docs/notes/pathb-stage2.md`, section 1 (amended for bytecode
producers). The IR's header names the producer: `(producer "lua-5.4")`.

## Pipeline

```
luac-format chunk (Lua 5.4.9)            tools/lua54bc/lua54_chunk.cpp      reader, decoder
  -> Path B IR text (s-expressions)      tools/lua54bc/lua54_lower.cpp      op table, one template per opcode
  -> QBE IL                              scripts/pathb-qbe-emit.rb          the existing emitter, unchanged except
                                                                             that it accepts the (producer ...) form
  -> assembly                            build/qbe/qbe
  -> executable                          with tests/lua54bc/runtime/        runtime helpers and a driver
```

`tests/lua54bc/lower/run.sh` runs the whole chain on each program in `tests/lua54bc/lower/`, compares the result with
`lua`'s, and checks that a program using CALL is refused.

## Value model

A Lua value is an `LV`, 16 bytes, align 8 (`(abi-type "LV" 16 8 (memory))` in the IR):

| offset | field |
| --- | --- |
| 0 | `u8` tag, the lobject.h variant (`nil` 0x00, `false` 0x01, `true` 0x11, integer 0x03, float 0x13; strings 0x04/0x14) |
| 8 | `i64` (integer) or `f64` (float) |

A register `R(i)` of a function is the address `base + 16*i`. A lowered function is

```
lua54_fn_N(LV *ret, LV *base)
```

`ret` receives the single result of `RETURN1` or `RETURN` with one value. Registers are not IR slots: they are addressed
through `base`, so the frame belongs to the caller. Temporaries for constants passed by address are IR slots
(`tmp.PC.K`).

Each IR function's numbers are pre-order over the prototypes of the chunk: `lua54_fn_0` is the main function.

## Op table

`lua54_lower.cpp` has one lowering function per opcode. An opcode with no entry, or an entry that refuses an operand
shape, is refused by name; nothing is dropped.

| opcode | lowering |
| --- | --- |
| `MOVE`, `LOADI`, `LOADF`, `LOADK` (numbers, booleans, nil), `LOADFALSE`, `LOADTRUE`, `LOADNIL` | inline stores and copies |
| `ADD`, `SUB`, `MUL`, `ADDI`, `ADDK`, `SUBK`, `MULK` | integer fast path (wrapping `wadd`/`wsub`/`wmul`); otherwise `lua54rt_arith` |
| `DIV`, `IDIV`, `MOD`, `POW`, `BAND`, `BOR`, `BXOR`, `SHL`, `SHR`, their `K` forms, `SHRI`, `SHLI` | `lua54rt_arith` (the helper does the whole op) |
| `UNM`, `BNOT` | `lua54rt_unary` |
| `NOT` | inline: true when the tag is nil or false |
| `MMBIN`, `MMBINI`, `MMBINK` | nothing: the binary op skips them on both paths |
| `EQ`, `LT`, `LE`, `EQI`, `LTI`, `LEI`, `GTI`, `GEI` | integer fast path; otherwise `lua54rt_cmp`; then the next `JMP` as `docondjump` does |
| `EQK` | `lua54rt_cmp` (no fast path) |
| `TEST` | truthiness from the tag (nil and false are falsy), then the next `JMP` |
| `JMP` | `goto` |
| `FORPREP`, `FORLOOP` | `lua54rt_forprep` and `lua54rt_forloop` (lvm.c's rules, integer and float loops) |
| `CLOSURE` (prototypes without upvalues) | `lua54rt_closure`, a closure object that holds the function's address |
| `CALL` (`B` fixed, `C` fixed) | `lua54rt_call`; the callee's base is `R[A+1]`, its result goes to `R[A]` |
| `TAILCALL` (`k` clear, `B` fixed) | a call, then the result is returned; the `RETURN` after it is unreachable |
| `RETURN0`, `RETURN1`, `RETURN` with `B` = 1 or 2 | `ret` gets nothing or `R[A]`, then `return` |
| `VARARGPREP` | nothing: registers keep their contents, and no lowered op reads varargs |

Refused for now: `LFALSESKIP`, `LOADKX`, `EXTRAARG`, `CALL` with `B = 0` or `C = 0`, `TAILCALL` with `k` or `B = 0`,
`RETURN` with several values or `k` set, `CLOSURE` of a prototype with upvalues, `VARARG`, `GETTABUP`, `GETTABLE`,
`GETI`, `GETFIELD`, `SETTABUP`, `SETTABLE`, `SETI`, `SETFIELD`, `NEWTABLE`, `SELF`, `CONCAT`, `CLOSE`, `TBC`,
`TFORPREP`, `TFORCALL`, `TFORLOOP`, `SETLIST`, `LEN`, `GETUPVAL`, `SETUPVAL`, `TESTSET`, and any string constant.

### Arithmetic and MMBIN

lvm.c runs the binary op and skips the following `MMBIN*` when the operands are numbers (`pc++`). A lowered binary op
does the same: an inline integer fast path for `ADD`, `SUB`, `MUL` (and their K and I forms), and otherwise the helper,
which performs the whole operation, metamethods included. The `MMBIN*` that follows is then never reached by falling
through, so it lowers to nothing. The helper must produce the same result and error as the `MMBIN` path would.

### Comparisons and jumps

A comparison is followed by a `JMP` in Lua 5.4 bytecode. `docondjump` takes that `JMP` when the condition equals the
instruction's `k` bit and skips it otherwise. The lowering computes the condition as a bool register, then branches to
the jump's destination or to the instruction after it.

### Calls

`CALL A B C` passes `R[A+1..]` as the callee's base, so the callee's registers are the caller's registers above `A`,
as in Lua's own stack. The callee is `lua54_fn_N(LV *ret, LV *base)`; `ret` is `R[A]`. The helper nil-fills the
parameters the caller did not pass. The IR function's numbers are the pre-order numbers of the prototypes.

## Runtime helpers

The IR calls these C functions. `tests/lua54bc/runtime/lua54rt.c` implements the number cases only; a non-number
operand stops the program with a message. The full runtime (metamethods, error messages, strings, GC) is separate work.

```
void lua54rt_arith(int op, LV *dst, LV *a, LV *b);   /* op: the Lua opcode, ADD (34), SUB (35) or MUL (36) */
int  lua54rt_cmp(int kind, LV *a, LV *b);            /* kind: 0 is <, 1 is <=, 2 is ==; returns 0 or 1 */
```

## Decisions

- **Registers are addresses, not slots.** The lowering knows nothing about the frame size; `base` is the caller's array.
- **Integer arithmetic wraps.** Lua integers are two's complement, so `wadd`, `wsub`, `wmul`. The test
  `wrap.lua` checks `maxinteger + 1`.
- **MMBIN folded into its op.** The helper does the metamethod work, so the MMBIN is never executed. This matches lvm.c
  on the success path. The error path needs the runtime's messages, which are not in place.
- **Strings are refused.** A string constant has no inline representation yet, so `LOADK` and comparisons with strings
  are refused rather than guessed.
- **One result.** `RETURN` with more than one value needs the stack top and is refused.
- **Refusal, not partial output.** A chunk with any refused function gives no IR at all.

## Verification

- `tests/lua54bc/run.sh`: the reader loads real 5.4.9 chunks (dumped with `string.dump`); the opcode sequence matches
  `luac -l -l` when `LUAC` is set. The opcode check has not run: no `luac` is available here.
- `tests/lua54bc/lower/run.sh`: six programs lower, emit, assemble, link and run, and match `lua`'s results; a CALL
  program is refused. Needs `LUA` (a 5.4.9 interpreter).
- The emitter's own tests (`tests/mruby/run.sh`) do not use `(producer ...)`, so the one-line change to accept it does
  not change their output.

## Not yet

Tables, strings, calls and closures, upvalues, numeric and generic `for` loops, the remaining operators, multiple
results and varargs, and the metamethod and error paths of the runtime. Each needs a template here and a helper in the
runtime, and each needs a test program checked against `lua`.
