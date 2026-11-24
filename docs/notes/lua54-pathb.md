# Lua 5.4 bytecode to Path B IR

Status, 2026-11-24: every opcode but `TBC` lowers, and 46 programs match Lua 5.4.9 (`tests/lua54bc/lower/run.sh`). The
runtime has numbers, strings, tables, closures and upvalues, multiple results, varargs, and the host functions `print`,
`type`, `tostring`, `pairs`, `next`, `ipairs`, `select`. No metamethods, no `string` library, and runtime errors stop the
program without Lua's messages. The producer rule for this IR is in `docs/notes/pathb-stage2.md`, section 1 (amended for bytecode
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

`lua54_lower.cpp` has one lowering function per opcode. The only opcode without one is `TBC` (a to-be-closed variable);
a chunk that has one is refused with `refused: opcode TBC ...`, and nothing is emitted for it.

| opcodes | lowering |
| --- | --- |
| `MOVE`, `LOADI`, `LOADF`, `LOADK`, `LOADKX`, `LOADFALSE`, `LFALSESKIP`, `LOADTRUE`, `LOADNIL` | inline stores and copies; string constants through `lua54rt_str` |
| `ADD`, `SUB`, `MUL`, `ADDI`, `ADDK`, `SUBK`, `MULK` | integer fast path (wrapping `wadd`/`wsub`/`wmul`); otherwise `lua54rt_arith` |
| `DIV`, `IDIV`, `MOD`, `POW`, `BAND`, `BOR`, `BXOR`, `SHL`, `SHR`, their `K` forms, `SHRI`, `SHLI` | `lua54rt_arith` (the helper does the whole op) |
| `UNM`, `BNOT` | `lua54rt_unary` |
| `NOT` | inline: true when the tag is nil or false |
| `MMBIN`, `MMBINI`, `MMBINK`, `EXTRAARG` | nothing: the binary op skips the `MMBIN*` on both paths; `EXTRAARG` is read by its owner |
| `EQ`, `LT`, `LE`, `EQI`, `LTI`, `LEI`, `GTI`, `GEI` | integer fast path; otherwise `lua54rt_cmp`; then the next `JMP` as `docondjump` does |
| `EQK` | `lua54rt_cmp` |
| `TEST`, `TESTSET` | truthiness from the tag (nil and false are falsy), then the next `JMP` (`TESTSET` copies `R[B]` to `R[A]` when it takes the jump) |
| `JMP` | `goto` |
| `FORPREP`, `FORLOOP` | `lua54rt_forprep` and `lua54rt_forloop` (lvm.c's rules, integer and float loops) |
| `TFORPREP`, `TFORCALL`, `TFORLOOP` | a call of `R[A]` with the state and control, results to `R[A+4..]`; the loop goes on while the first result is not nil |
| `NEWTABLE`, `SETLIST` (with or without `EXTRAARG`) | `lua54rt_newtable`, `lua54rt_setlist` |
| `GETTABLE`, `GETI`, `GETFIELD`, `GETTABUP` | `lua54rt_gettable` (`GETTABUP` loads the upvalue first, for `_ENV`) |
| `SETTABLE`, `SETI`, `SETFIELD`, `SETTABUP` | `lua54rt_settable` |
| `SELF` | a copy of the object to `R[A+1]`, then `lua54rt_gettable` |
| `LEN` | `lua54rt_len` (strings and tables) |
| `CONCAT` | `lua54rt_concat` (strings and numbers) |
| `CLOSURE` | `lua54rt_closure` and `lua54rt_capture` for each upvalue (from the frame or the enclosing closure) |
| `GETUPVAL`, `SETUPVAL`, `CLOSE` | `lua54rt_getupval`, `lua54rt_setupval`, `lua54rt_close` |
| `CALL`, `TAILCALL` | `lua54rt_call`; `B = 0` takes the arguments up to the stack top, `C = 0` leaves all results and the top |
| `RETURN`, `RETURN0`, `RETURN1` | `lua54rt_setret` (`B = 0` returns up to the top); `k` closes the frame's upvalues first |
| `VARARGPREP`, `VARARG` | `lua54rt_varargprep` saves the extra arguments; `lua54rt_vararg` copies them (`C = 0` sets the top) |

### Calls

A function is `lua54_fn_N(LV *ret, LV *base, void *cl)`: `ret` is the caller's `R[A]`, `base` the frame (the caller's
`R[A+1]`), `cl` the closure. A callee writes its results to `ret[0..n-1]` and `lua54rt_setret` records `n`. The caller's
`lua54rt_call` fills the missing parameters with nil and, for `C - 1` results, nil-fills the rest. With `C = 0` it sets
the stack top to `A + n`; the next op that takes "up to top" (`CALL B = 0`, `RETURN B = 0`, `SETLIST B = 0`,
`TAILCALL`) reads it at once. A vararg function saves its extra arguments at `VARARGPREP`, while their count is
still known. The IR function numbers are the pre-order numbers of the prototypes.

### Arithmetic and MMBIN

lvm.c runs the binary op and skips the following `MMBIN*` when the operands are numbers (`pc++`). A lowered binary op
does the same: an inline integer fast path for `ADD`, `SUB`, `MUL` (and their K and I forms), and otherwise the helper,
which performs the whole operation, metamethods included. The `MMBIN*` that follows is then never reached by falling
through, so it lowers to nothing. The helper must produce the same result and error as the `MMBIN` path would.

### Comparisons and jumps

A comparison is followed by a `JMP` in Lua 5.4 bytecode. `docondjump` takes that `JMP` when the condition equals the
instruction's `k` bit and skips it otherwise. The lowering computes the condition as a bool register, then branches to
the jump's destination or to the instruction after it.

## Runtime helpers

The IR calls these C functions. `tests/lua54bc/runtime/lua54rt.c` implements them; `driver.c` runs the main function and
prints its results the way `print` does. Metamethods are not implemented: an operation that would need one stops the
program with a message.

```
arith(op, dst, a, b)              binary ops with Lua's rules; op is the base opcode (ADD=34 .. SHR=45)
unary(op, dst, a)                 UNM (49), BNOT (50)
forprep(ra) / forloop(ra)         numeric for, lvm.c's rules; return 1 to skip / to jump back
cmp(kind, a, b)                   0 is <, 1 is <=, 2 is ==; returns 0 or 1
closure(dst, fn, nparams, nups) / capture(dst, k, instack, idx, encl, base) / getupval / setupval / close
call(fn, nargs, args, ret, wanted, a) / setret(ret, src, n) / gettop()
varargprep(base, nfixed) / vararg(va, dst, wanted, a)
str(dst, p, len) / newtable(dst) / gettable(dst, t, k) / settable(t, k, v) / len(dst, src)
concat(dst, base, n) / setlist(t, offset, vals, count)
make_main(fn, nups) / run_main(cl, out, outsize)
```

## Decisions

- **Registers are addresses, not slots.** The lowering knows nothing about the frame size; `base` is the caller's array.
  The runtime's stack has 65536 values, and a call does not check for overflow.
- **Integer arithmetic wraps.** Lua integers are two's complement, so `wadd`, `wsub`, `wmul`. The test
  `wrap.lua` checks `maxinteger + 1`.
- **MMBIN folded into its op.** The helper does the metamethod work, so the MMBIN is never executed. This matches lvm.c
  on the success path. The error path needs the runtime's messages, which are not in place.
- **One result type per helper, one protocol for calls.** Results and the top go through `lua54rt_setret`,
  `lua54rt_call` and `lua54rt_gettop`; no global is read by the IR.
- **Strings are objects without interning.** Each string constant and each result is a new object. Equality compares the
  bytes, so behaviour is the same, only the cost differs.
- **Refusal, not partial output.** A chunk with a `TBC` gives no IR at all.

## Verification

- `tests/lua54bc/run.sh`: the reader loads real 5.4.9 chunks (dumped with `string.dump`); the opcode sequence matches
  `luac -l -l` when `LUAC` is set. The opcode check has not run: no `luac` is available here.
- `tests/lua54bc/lower/run.sh`: 41 programs lower, emit, assemble, link (with `-lm`), run, and match `print(dofile(...))`
  from Lua 5.4.9; a `TBC` program is refused. Needs `LUA` (a 5.4.9 interpreter).
- The emitter's own tests (`tests/mruby/run.sh`) do not use `(producer ...)`, so the one-line change to accept it does
  not change their output.

## Not yet

- **The rest of the base library** (`error`, `pcall`, `tonumber`, `rawget`, `setmetatable`, ...) and the `string`,
  `table` and `math` libraries. Each is a host function in the runtime, like the ones there.
- **Metamethods**: `__index`, `__newindex`, `__add` and the rest, `__eq`, `__lt`, `__le`, `__concat`, `__len`, `__call`.
  Today a table without them is the only kind that works: the helpers stop on anything else.
- **Errors**: Lua's messages with `file:line:` and variable names (`attempt to index a nil value (local 'x')`). The IR has
  no line information yet; the reader has `lineinfo`, and a helper call could take the line.
- **String coercion** in arithmetic (`"10" + 1`), and `tostring`-style conversion of strings to numbers.
- **To-be-closed variables** (`TBC`, and the fourth value of a generic `for`).
- **Length of tables with holes**: `#` counts from 1 up to the first nil, which is one border; Lua's `#` can pick another.
- **Garbage collection**: nothing is freed. Tests are short; a real runtime needs a collector and root maps.
- **`LOADKX` with more than 2^17 constants** is lowered but untested.
