# Lua 5.4 bytecode to Path B IR

Status: every opcode lowers. 83 programs match Lua 5.4.9 (`tests/lua54bc/lower/run.sh`), and 47 error programs print the
same first line as lua.c, with its position, message and variable info. The runtime has numbers with coercion, strings
with the string metatable, tables with metatables, closures and upvalues, multiple results, varargs, the metamethods
listed below, to-be-closed variables, protected calls (`pcall` and `xpcall`, with `error` and its levels, and `assert`),
and the libraries: base (`print`, `type`, `tostring`, `tonumber`, `pairs`, `next`, `ipairs`, `select` with negative
indices, `setmetatable`, `getmetatable`, `rawget`, `rawset`, `rawequal`, `rawlen`, `_G`, `_VERSION`), `table` (`insert`,
`remove`, `concat`, `unpack`, `pack`, `move`, `sort`), `math` (`floor`, `ceil`, `abs`, `max`, `min`, `sqrt`, `tointeger`,
`fmod`, `modf`, `exp`, `log`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `ult`, `type`, `random`, `randomseed`, `huge`,
`pi`, `maxinteger`, `mininteger`), `string` (`len`, `sub`, `upper`, `lower`, `rep`, `reverse`, `byte`, `char`, `format`
with `%a` and `%q`, `find`, `match`, `gmatch`, `gsub`), `os` (`clock`, `time`, `getenv`, `exit`) and `io` (`write`, and
`io.stdout:write`).

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
`lua`'s, and checks the error programs' first line and status.

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

`lua54_lower.cpp` has one lowering function per opcode, and every opcode has one. A chunk with an opcode that has none is
refused (`refused: opcode ... is not lowered yet`), and nothing is emitted for it.

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
| `TBC` | `lua54rt_tbc`: the slot is registered to be closed (nil and false are not; another value needs `__close`) |
| `TFORPREP`, `TFORCALL`, `TFORLOOP` | `TFORPREP` registers the fourth value (the closing value) as `TBC` does; `TFORCALL` calls `R[A]` with the state and control, results to `R[A+4..]`; the loop goes on while the first result is not nil |
| `NEWTABLE`, `SETLIST` (with or without `EXTRAARG`) | `lua54rt_newtable` (the size hints of lvm.c), `lua54rt_setlist` (grows the array part at once, then stores into it) |
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

## Errors

An operation that can fail is preceded by its site: `lua54rt_site` points at a data string whose first line is
`source:line:` (lua.c's position, from the line table) and whose further lines are the variable info of each operand.
The info is computed here with ldebug.c's rules (`namespace dbg` in `lua54_lower.cpp`: `getobjname`, `findsetreg`,
`basicgetobjname`, `isEnv`, `getfuncline`), so the runtime prints `local 'x'`, `global 'x'`, `field 'x'`, `method 'x'`,
`upvalue 'x'`, `constant 'x'` and `for iterator 'for iterator'` as lua.c does. The source name keeps luaO_chunkid's
truncation (the last 56 characters after `...`).

An error goes to stderr as `lua: <site line> <message><info>` and the process stops with status 1, as lua.c does. Only
the first line is printed: the traceback is not. The run checks that first line, after the progname, against `lua`.

`error(msg, level)` finds the position of its level in a call stack that the runtime keeps: each call pushes the position
of its caller (NULL when the caller is not a Lua function, as for a call from `pcall`), so a host function is a level with
no position, as in Lua. `pcall` and `xpcall` restore the depth when an error comes back to them. A tail call does not
drop its frame here, so the level of an error in a tail-called function is one more than Lua's.

To-be-closed variables: `TBC` registers the variable's slot, and `CLOSE`, `RETURN` with `k`, and the end of a `pcall`
that caught an error close the slots at or above the given one, last registered first. Each `__close` gets the value and
the error (nil when the block ends normally). An uncaught error closes them too, before lua.c's message. Not done: an
error inside a `__close` during an error's unwinding replaces the error in Lua; here it goes to the next protected call
out.

## Garbage collection

The runtime has a mark-and-sweep collector. Every object (strings, tables, closures, upvalues, host functions, saved
varargs) starts with a header and is linked into one list and into a set of addresses. A collection marks from:

- the Lua stack (`lua_stack`, all of it: a stale slot holds an address that is no longer in the set, so it is ignored);
- the open upvalues, the string metatable, the `next` and `ipairs` iterators, and the running main closure;
- the state values of host closures (`HostFn.up`, the subject and pattern of a `gmatch` iterator and its positions);
- the C stack, conservatively. The helpers keep values in their locals, so every word of the C stack that is the address
  of an object in the set counts as a reference (`__builtin_unwind_init` and `setjmp` put the registers on the stack).

The sweep frees the unmarked objects. A collection runs when the bytes allocated since the last one exceed a threshold
of at least 4 MB, or twice the live bytes. The collector is off until the main function starts, since the stack top is
recorded then. `collectgarbage` supports `collect`, `step`, `count` (KB), `isrunning`, `stop` and `restart`.

The suite runs twice: normally, and with `LUA54RT_GC_THRESHOLD=1`, which collects at nearly every allocation. Both pass.
On the garbage-heavy program (`gc_garbage.lua`) the peak resident size is 19 MB with collection, against 90 MB without.

Not done: weak tables (`__mode`), finalizers (`__gc`), and incremental or generational collection.

## Metamethods

Implemented in the runtime, with ltm.c's order (the first operand's metatable, then the second's):
`__index` and `__newindex` (tables, functions, and chains), `__call`, the arithmetic and bitwise events, `__unm`,
`__bnot`, `__eq` (for two tables), `__lt`, `__le`, `__concat` (pairwise from the right, as luaV_concat), `__len`,
`__tostring` (in `print` and `tostring`). Strings convert to numbers in arithmetic, and a string that does not convert
gives lstrlib's `attempt to add a 'string' with a 'number'`. Only tables have metatables, and the string metatable.

`__metatable` (`getmetatable` returns the field, `setmetatable` gives lbaselib's `cannot change a protected metatable`),
`__pairs` (`pairs` returns the metamethod's three results; without it, `next`, the value and nil, so `pairs(nil)` fails in
`next` as `for iterator`) and `__name` (in `luaL_typeerror`'s `got <name>` and in luaG_typeerror's `attempt to ... a
<name> value`, and in `tostring`).

## Decisions

- **Registers are addresses, not slots.** The lowering knows nothing about the frame size; `base` is the caller's array.
  The runtime's stack has 65536 values, and a call does not check for overflow.
- **Integer arithmetic wraps.** Lua integers are two's complement, so `wadd`, `wsub`, `wmul`. The test
  `wrap.lua` checks `maxinteger + 1`.
- **MMBIN folded into its op.** The helper does the metamethod work, so the MMBIN is never executed. This matches lvm.c
  on the success path.
- **One result type per helper, one protocol for calls.** Results and the top go through `lua54rt_setret`,
  `lua54rt_call` and `lua54rt_gettop`; no global is read by the IR.
- **Strings are objects without interning.** Each string constant and each result is a new object. Equality compares the
  bytes, so behaviour is the same, only the cost differs.
- **Refusal, not partial output.** A chunk with an opcode that has no lowering gives no IR at all.

## Verification

- `tests/lua54bc/run.sh`: the reader loads real 5.4.9 chunks (dumped with `string.dump`); the opcode sequence matches
  `luac -l -l` when `LUAC` is set. The opcode check has not run: no `luac` is available here.
- `tests/lua54bc/lower/run.sh`: 83 programs lower, emit, assemble, link (with `-lm`), run, and match
  `print(dofile(...))` from Lua 5.4.9. 47 programs in `lower/err/` must give lua.c's first error line and status 1. Needs
  `LUA` (a 5.4.9 interpreter). The suite also passes with `LUA54RT_GC_THRESHOLD=1`, which collects at nearly every
  allocation.

## String patterns

`string.find`, `string.match`, `string.gmatch` and `string.gsub` in `lua54rt.c` (the section "string: pattern matching")
are a direct port of lstrlib.c's matcher: `pat_match` is `match` with the same `goto`s, and `pat_classend`,
`pat_match_class`, `pat_match_bracket_class`, `pat_single_match`, `pat_matchbalance`, `pat_max_expand`,
`pat_min_expand`, `pat_start_capture`, `pat_end_capture` and `pat_match_capture` follow their namesakes. The same limits
apply (32 captures, a match depth of 200, "pattern too complex"), and the error messages are lstrlib's.

Covered: every class (`%a %c %d %g %l %p %s %u %w %x %z` and their complements, and any other escaped character as
itself), sets with ranges and complements, `* + - ?`, the anchors `^` (at the start of `find`, `match` and `gsub`) and
`$`, captures, position captures `()`, `%b`, `%f`, back-references `%1`..`%9`, the `init` argument (negative counts
from the end), the plain flag of `find`, and the replacement of `gsub` as a string (`%0`..`%9`, `%%`), a table (indexed
by the first capture) or a function (called with the captures), with the optional maximum count. A `false` or `nil`
result keeps the match; a number result is converted; any other result is `invalid replacement value`.

`gmatch` returns a host closure whose state is in `HostFn.up[0..3]`: the subject, the pattern, the position to search
from and the end of the last match (-1 for none). A host function reads its own closure through `cur_host`, which
`lua54rt_call` sets for the call; the iterator is the only one that needs it. Like lstrlib's `gmatch`, a `^` is not an
anchor there.

Not done: the `gsub` buffer is `malloc`ed, so an error raised in the middle of a `gsub` (a bad replacement, or an error
in the replacement function) leaks that buffer. The matcher's recursion is on the C stack, bounded by the depth of 200.

## Not yet

- **The rest of the libraries**: `load`, `dofile`, `require` (they compile at run time, which the AOT path does not
  do), `string.pack`, `unpack`, `packsize`, `dump`, `utf8`, `coroutine`, the rest of `os` (`date`, `difftime`, ...)
  and `io` (`read`, files). Each is a host function in the runtime.
- **Library names in messages**: a `pcall` that calls a library function directly gives `'rep'` where Lua gives
  `'string.rep'`, and `math.random(2, 1)` called through `pcall` is `'random'` here. Calls from Lua code are the same.
- **Full tracebacks**: lua.c prints `stack traceback:` lines after the message; only the message is printed.
- **`__gc`, `__mode`**.
- **Length of tables with holes**: `#` counts from 1 up to the first nil, which is one border; Lua's `#` can pick another.
- **`LOADKX` with more than 2^17 constants** is lowered but untested.
