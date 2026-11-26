# mruby bytecode producer for Path B (tools/mrbbc)

Status: first implementation. A RITE reader for mruby 4.0.0 files, a dump tool, and a lowering of an integer subset of the
root irep to the Path B IR. The IR is the contract of `docs/notes/pathb-stage2.md`; this producer follows section 1 (a
bytecode producer decodes an image and emits the IR; runtime concerns stay with the producer; a language runtime is
reached through `(call ...)` into a C file). It is the mruby counterpart of the Lua 5.4 producer (`tools/lua54bc`,
`docs/notes/lua54-pathb.md`) and the MicroPython one (`tools/mpy`).

Pin: mruby 4.0.0 (`831da26b`, `scripts/setup-mruby.sh`). The reference interpreter is `build/mruby-tool/bin/mruby`. The
compiler is `build/mruby-tool/out/host/mrbc/bin/mrbc`, built by the same ninja run (the setup script installs only
`bin/mruby`). The sources are in `build/mruby-tool/src`.

## Files

| File | What it is |
| --- | --- |
| `tools/mrbbc/mrb_opcodes.inc` | The opcode table: `OPCODE(name, format)` for the 119 opcodes of `include/mruby/ops.h`, in enum order. |
| `tools/mrbbc/mrb_rite.hpp`, `mrb_rite.cpp` | The RITE 04.00 reader (`read_module`) and the instruction decoder (`decode_iseq`). |
| `tools/mrbbc/mrbbc_dump.cpp` | Prints the ireps, pools, symbols, locals and instructions of a RITE file. |
| `tools/mrbbc/mrb_lower.hpp`, `mrb_lower.cpp` | The lowering of the root irep to IR text. |
| `tools/mrbbc/mrbbc_lower_main.cpp` | `mrbbc_lower program.rite > program.ir`. |
| `tests/mrbbc/runtime/mrbrt.{h,c}`, `driver.c` | The runtime: the tagged value, integer operators, error exits, the program's entry point. |
| `tests/mrbbc/corpus/*.rb` | Programs for the reader suite. |
| `tests/mrbbc/reader/run.sh` | The reader suite. |
| `tests/mrbbc/lower/*.rb`, `lower/rterr/`, `lower/err/`, `lower/run.sh` | The end-to-end suite. |

Run both suites from the repository root (they need `build/`, see docs/notes/mruby-scripting.md):

```
tests/mrbbc/reader/run.sh
tests/mrbbc/lower/run.sh
```

Both exit 77 when mrbc, the mruby interpreter or QBE is missing; `MRBC`, `MRUBY` and `QBE` override the paths.

## The RITE 04.00 format (as mruby 4.0.0 writes and reads it)

The layouts come from `src/dump.c` (writer) and `src/load.c` (reader). Corrections to the first brief, found from the
sources:

- The file starts `RITE0400`, not `RITE0300`: the binary format version is 04.00 and the IREP section's VM version is
  `0400`. The reader accepts only 04.00.
- Header (20 bytes): `RITE`, major `04`, minor `00`, `binary_size` at byte 8 (u32, the whole file), `MATZ`, `0000`.
- Sections: `IREP` (12-byte header with the VM version, then the irep tree), optional `DBG\0`, optional `LVAR`, then
  `END\0` with size 8, which must be the last bytes of the file. mrbc writes LVAR by default (`--remove-lv` omits it)
  and DBG with `-g`.
- Multi-byte integers are big-endian. A float constant is a little-endian double.
- An irep record: u32 record size, u16 nlocals, u16 nregs, u16 child count, u16 catch count, u32 ilen (iseq bytes),
  the iseq, the catch table (13 bytes each: u8 type, u32 begin, u32 end, u32 target), the pool, the symbols. The record
  size counts the record without its children; the children follow the record in order.
- Pool entries start with a type byte: 0 string (u16 length, bytes, NUL), 1 int32, 3 int64 (high word, low word),
  5 float, 7 bigint. A bigint is a length byte, a base byte and the digits in that base, as ASCII; a negative base byte
  means a negative number. mruby writes `-2147483648` this way (`new_litbint(s, "2147483648", -10)` in `codegen.c`).
- Symbols: u16 length (0xFFFF for a null symbol), the name, NUL. LVAR names have no NUL.
- Instructions: one opcode byte and its operands, with the formats of `ops.h` (B, BB, BBB, BS, BSS, S, W, Z; S is a
  signed 16-bit offset). An `EXT1`/`EXT2`/`EXT3` prefix is an instruction of its own; the instruction after it has its
  operands widened by the `FETCH_*_n` macros of `ops.h` (16-bit first operand for EXT1, a 16-bit second one for EXT2,
  and both 16-bit for EXT3). `mrbc` uses a prefix when a register is past 255.

`mrb::decode_iseq` throws on an opcode out of range, a prefix with no instruction after it, or an instruction that runs
past the iseq. The reader checks every section size and the record sizes, rejects bytes after END, and rejects a
DBG or LVAR section before IREP.

## The lowering

### Values and registers

A register R(i) is a 16-byte slot `r<i>` of type `MV`: the tag byte at offset 0 and an int64 at offset 8. The tags are
the runtime's (`tests/mrbbc/runtime/mrbrt.h`): nil 0, false 1, true 2, integer 3. The main program becomes one IR
function `mrb_irep_0(MV *ret)`. A `RETURN` copies R(a) into `*ret`, and the driver prints `*ret`.

Integer operators have an inline fast path. When every operand has the integer tag, `+`, `-` and `*` are the IR's
checked `cadd`, `csub` and `cmul` (they trap on overflow), and `<`, `<=`, `>`, `>=` are signed `lt.s` and `le.s` (the
operands of `>` and `>=` are swapped). Everything else calls `mrbbc_binop`, which does the rest of mruby's rules.

### Opcodes

Lowered (`mrb_lower.cpp`):

| Group | Opcodes |
| --- | --- |
| No-op | `NOP` |
| Moves and constants | `MOVE`, `LOADI__1`, `LOADI_0` ... `LOADI_7`, `LOADI8`, `LOADINEG`, `LOADI16`, `LOADI32`, `LOADL` (integer or bigint constants that fit in 64 bits), `LOADNIL`, `LOADTRUE`, `LOADFALSE` |
| Integer arithmetic | `ADD`, `SUB`, `MUL`, `DIV` (floor division, as mruby), `ADDI`, `SUBI`, `ADDILV`, `SUBILV` (the last two add an 8-bit immediate; `ADDILV a b c` adds `c` to local `a`, as `i += 1` compiles to) |
| Comparison | `EQ` (identity on nil, booleans and integers), `LT`, `LE`, `GT`, `GE` |
| Jumps | `JMP`, `JMPUW` (the same as JMP when the irep has no catch table, which is checked; mruby emits it for `break`), `JMPIF`, `JMPNOT`, `JMPNIL` |
| Returns | `RETURN`, `RETNIL`, `RETFALSE`, `RETTRUE`, `STOP` (nil, as `vm.c` returns) |

Refused by name (exit 3, `refused: opcode NAME is not lowered yet (pc N)`): every other opcode, the `EXT1`-`EXT3`
prefixes and the instructions they widen, `LOADL` of a non-integer, and a main program with a catch table. In
particular a method call (`SEND`), a string, an array, a float, a symbol, an instance or global variable, a block,
a class or a method definition, and `ENTER` (parameters) are refused.

### The printed result

The value a program prints is the value its `RETURN` returns, which mruby compiles from the last expression of the
top level. The reference is the pinned mruby on the same file with the last line replaced by `p(<that line>)`, so each
value program ends in one expression on one line. The driver prints nil, true, false or the decimal integer, as `p`
does.

### Runtime errors

An uncaught error exits 1, and the last stderr line is `NAME: MESSAGE (CLASS)`. The suite compares the text after the
last `: ` of that line with the same text from mruby (its last line is `file:line: MESSAGE (CLASS)`, or
`file:line:in OP: MESSAGE (CLASS)`). The messages of mruby 4.0.0 that the runtime reproduces (probed, not taken from the
sources):

| Case | Message |
| --- | --- |
| nil, true or false receiver of `+ - * / < <= > >=` | `undefined method '+' for NilClass` (NoMethodError); the class names are `NilClass`, `TrueClass`, `FalseClass` |
| integer `/` by zero | `divided by 0` (ZeroDivisionError) |
| integer `+` or `-` with nil | `can't convert nil into Float` (TypeError) |
| integer `+` or `-` with true or false | `true cannot be converted to Float` (TypeError) |
| integer `*` or `/` with nil, true or false | `can't convert nil into Integer` (TypeError) |
| integer `<` (and the other comparisons) with nil, true or false | `comparison of Integer with NilClass failed` (ArgumentError) |

`==` never raises on these values.

## Deviations from mruby

- **Integer overflow.** mruby promotes an overflowing `+ - *` (and `INT_MIN / -1`) to a Bignum or a Float. The inline
  path traps (the IR's checked operations abort, SIGABRT); the runtime path raises `NotImplementedError`. The corpus
  avoids overflow. Values up to 2^63 - 1 are exact.
- **Integer width.** This build uses mruby's default word boxing (`MRB_WORD_BOXING`), so its immediate integers are
  narrower than 64 bits and larger values are heap objects. The producer uses 64-bit integers throughout. The corpus
  stays within the immediate range, so the comparison with mruby does not test that boundary.
- **Refusals in place of silence.** Everything outside the subset is refused at lowering time, never compiled to a
  wrong value.

## Tests

- Reader (`tests/mrbbc/reader/run.sh`): 6 corpus programs and one generated program with registers past 255 (EXT1),
  each compiled four ways (default, `-g`, `--remove-lv`, `-g --remove-lv`): 28 files read by `mrbbc_dump` (every
  instruction decodes, no bytes after END) and run to status 0 by the pinned mruby. 15 malformed files (truncations,
  an extra byte, a wrong magic, format 03.00, an unknown section, an opcode out of range) are refused with status 1.
- Lowering (`tests/mrbbc/lower/run.sh`): 13 value programs (one generated: 200 locals) match mruby's `p`; 9 runtime
  errors match mruby's last stderr line and status 1; 12 programs in `err/` and a generated one with EXT1 prefixes
  are refused with status 3, a `refused:` message and no stdout. `err/` is the refusal set, `rterr/` the runtime
  errors; the brief's "err/ programs must be refused" is read as the first.

## Open questions

- The brief names `LOADI`; mruby 4.0.0 has no such opcode. The integer loads are `LOADI__1`, `LOADI_0`..`LOADI_7`,
  `LOADI8`, `LOADINEG`, `LOADI16`, `LOADI32` and `LOADL` (the pool), all lowered.
- The IR gained no form: the producer uses the existing forms (`let`, `slot`, `offset`, `load`, `store`, `copy`,
  `cadd`, `csub`, `cmul`, `lt.s`, `le.s`, `lt.u`, `le.u`, `eq`, `if`, `goto`, `label`, `return`, `call` under `eval`).
- `__nfcxx_smul64_ovf` is needed by the emitter's checked 64-bit multiply and is defined in `be/nfcxx_ldrt.c`. The
  runtime here defines the same one-line function rather than linking the shared runtime.
- The reader's DBG section is read for its size and dropped; line information is not used yet, so runtime errors print
  the program name where mruby prints `file:line`.
