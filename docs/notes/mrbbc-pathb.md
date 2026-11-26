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
| `tests/mrbbc/runtime/mrbrt.{h,c}`, `driver.c` | The runtime: the tagged value, heap strings, arrays and symbols, the operators, indexing, the SEND0 methods, the classes and objects of the program, the blocks and breaks, the inspect printer, error exits, the program's entry point. |
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
the runtime's (`tests/mrbbc/runtime/mrbrt.h`): nil 0, false 1, true 2, integer 3, string 4, array 5, symbol 6. The
int64 of a string, an array or a symbol is a pointer to the runtime's object: a string is a length and its bytes, an
array a length, a capacity and its `MV` items, a symbol the NUL-terminated name in the module's data. The objects are
malloc'd and never freed, since there is no collector. The main program becomes one IR function `mrb_irep_0(MV *ret)`.
A `RETURN` copies R(a) into `*ret`, and the driver prints `*ret` the way `p` does.

Integer operators have an inline fast path. When every operand has the integer tag, `+`, `-` and `*` are the IR's
checked `cadd`, `csub` and `cmul` (they trap on overflow), and `<`, `<=`, `>`, `>=` are signed `lt.s` and `le.s` (the
operands of `>` and `>=` are swapped). Everything else calls `mrbbc_binop`, which does the rest of mruby's rules for
integers, strings, arrays and symbols (`==` compares contents: strings by bytes, arrays element by element).

String literals and symbol names are data items of the IR module: `(data "mrbbc_strPC" (const (array N (const char)))
(string "..."))` for a `STRING` at pc PC, and one `mrbbc_symK` per distinct symbol name. Temporaries that the array
literals are built in are extra `MV` slots of the function.

### Opcodes

Lowered (`mrb_lower.cpp`):

| Group | Opcodes |
| --- | --- |
| No-op | `NOP` |
| Moves and constants | `MOVE`, `LOADI__1`, `LOADI_0` ... `LOADI_7`, `LOADI8`, `LOADINEG`, `LOADI16`, `LOADI32`, `LOADL` (integer or bigint constants that fit in 64 bits), `LOADNIL`, `LOADTRUE`, `LOADFALSE` |
| Integer arithmetic | `ADD`, `SUB`, `MUL`, `DIV` (floor division, as mruby), `ADDI`, `SUBI`, `ADDILV`, `SUBILV` (the last two add an 8-bit immediate; `ADDILV a b c` adds `c` to local `a`, as `i += 1` compiles to) |
| Comparison | `EQ` (identity on nil, booleans and integers; contents on strings and symbols; elementwise on arrays), `LT`, `LE`, `GT`, `GE` |
| Strings and symbols | `STRING` (a new string of a pool entry), `STRCAT` (`R[a] << to_s(R[a+1])`, for `"#{x}"`), `LOADSYM` (a symbol with a plain name: an identifier, optionally ending in `?`, `!` or `=`) |
| Arrays | `ARRAY`, `ARRAY2` (a new array of registers), `ARYPUSH` (push R[a+1..a+b] onto R[a]), `GETIDX`, `GETIDX0` (`R[a] = R[b][0]`), `SETIDX` (`R[a][R[a+1]] = R[a+2]`, and R[a] gets the value, as `vm.c` does) |
| Methods | `SEND0` with `to_s`, `size`, `length` or `!`; `SEND` with one argument and an operator (`+ - * / == != < <= > >=`, which is the binop of the opcode); see the method table below |
| Jumps | `JMP`, `JMPUW` (the same as JMP when the irep has no catch table, which is checked; mruby emits it for `break`), `JMPIF`, `JMPNOT`, `JMPNIL` |
| Returns | `RETURN`, `RETNIL`, `RETFALSE`, `RETTRUE`, `STOP` (nil, as `vm.c` returns) |
| Methods of the program | `TDEF` (defines the body of child c as the method `Syms[b]` on Object at the top level, or on the class that a class body's self is, and R[a] becomes the symbol, as `vm.c` sets it), `SSEND0`, `SSEND` and `SSENDB` (a self call, R[a] = self's method, with up to 15 positional arguments and, for SSENDB, a block in R[a+n+1]); `SEND0`, `SEND` and `SENDB` with an explicit receiver of a method the program defines in a class; see "Methods" |
| Classes | `CLASS` (defines or reopens a class with no superclass), `EXEC` (runs a class body with self R[a]), `TCLASS` (the class a def goes to), `GETCONST` (a class by its name), `GETIV` and `SETIV` (an instance variable of self), `RETSELF` (in a method, a block or a class body); see "Classes" |
| Break | `BREAK` (from a block, to the call the block was passed to); see "Blocks" |
| Blocks | `BLOCK` (a block made from child b, closed over this frame), `BLKPUSH` (the method's own block, in a method), `BLKCALL` (yield), `GETUPVAR` and `SETUPVAR` at level 0 (the frame the block was made in); see "Blocks" |
| Parameters | `ENTER` with required parameters only (in a method or a block, at pc 0; the prologue copies them; a block may have two or more) |

The method table. A `SEND0` or `SEND` (with `c` = n | k<<4, so n = 0 or 1 and k = 0) names its method by a symbol. A
method outside the table is refused at lowering time with `refused: SEND0 of method 'NAME' is not lowered yet (pc N)`:

| Method | Receiver and result |
| --- | --- |
| `to_s` | integer, nil, true, false, symbol, string (itself), array (its inspect) |
| `size`, `length` | string and array (byte count and length); symbol (its name's length); `size` of an integer is 8, as `sizeof(mrb_int)` |
| `!` | any value: true for nil and false |
| `+ - * / == != < <= > >=` (one argument) | the binop helper, as the opcode |

### Methods

A method is a child irep that a `TDEF` names. Each such body is a function of its own,
`mrb_m<N>(MV *ret, MV *argv, MV *blk)`, numbered over the module in the order the TDEFs are found (the main program is
`mrb_irep_0`, as before). `argv[0]` is self and `argv[1..m]` are the m required arguments: the prologue copies them into
R(0)..R(m) and sets the other registers to nil. `blk` is the block the call gave, or a nil value. A method's ENTER must
be its first instruction and have only required parameters (aspec bits 0..17 zero, bit 23 zero); any other parameter is
refused.

Frames: every function keeps its registers in one contiguous slot, `frame`, of 16 bytes per register, and R(i) is the
register number 4 + i of the IR (the emitter names registers by digits only). The frame's address is what a BLOCK stores
for its closure.

- `TDEF a b c` calls `mrbbc_def(name, N, m)`, which adds the method to the runtime's table (Object, the only class
  a program of this subset defines methods on), then R[a] = the symbol, as `vm.c` sets it. A redefinition wins.
- `SSEND0 a b`, `SSEND a b c` and `SSENDB a b c` (self's method, with `n` = c arguments): the arguments R[a+1..a+n] are
  copied into a vector of their own, self first. `mrbbc_find(name, n)` returns the number of the latest definition of
  the name, or raises. The call is then one branch per method of the module: `if id == N then mrb_m<N>(&R[a], argv,
  blk)`, where blk is R[a+n+1] for SSENDB and a nil slot otherwise. A method's return writes R[a] through `ret`, so the
  caller's register gets the result as `RETURN` gives it.
- Only names the program defines are lowered for a self call (`sh.defined`). A self call to a name the program does not
  define is refused, so `foo` with no `def foo` is not in the lowered set, and the `NoMethodError` of an undefined
  method comes only from a name the program defines later (the call runs before its TDEF).
- `SEND` and `SEND0` (an explicit receiver) of a name the program defines are refused: a method of Object is private
  there and is reached only by a self call.

Messages (checked against mruby 4.0.0 by the `rterr/` programs): a self call before its TDEF runs gives
`undefined method 'NAME' for Object` (NoMethodError); a call with the wrong count gives
`wrong number of arguments (given N, expected M)` (ArgumentError). Both are raised by the runtime.

Deviation: a self call to an Object or Kernel method that the program also defines (`to_s`, `inspect`, `p`, ...) is
refused, because before the TDEF runs mruby calls the inherited one. The list of those names is `object_method` in
`mrb_lower.cpp`; a name missing from it would be a miscompile, so the list is conservative.

### Classes

A class body is a child irep that an `EXEC` runs, as the function `mrb_k<N>(MV *ret, MV *argv, MV *blk)` (numbered over
the module like the methods); argv[0] is the class, which is self (R(0)) in the body. mruby compiles `class Foo` at the
top level to `LOADNIL` (the cbase and the superclass), `CLASS a b` and `EXEC a b`, and a `class` inside a class body the
same way: the cbase is nil there too, so the class is defined under the body's self.

- `CLASS a b` (`mrbbc_class`): R[a] = the class Syms[b], defined under the class R[a] names, else under the class body's
  self, else at the top level. A class of the name that exists is reopened. A superclass (R[a+1] not nil) is a
  NotImplementedError at run time. The names of the core classes are refused the same way.
- `TCLASS a`: R[a] = Object at the top level, the class body's self in a class body (a method or a block is refused).
- `EXEC a b`: runs class body b with self R[a] and R[a] = its value (`mrb_k<N>`, called directly: the child is static).
- `TDEF` in a class body defines the method on that class (`mrbbc_def_in` with self), at the top level on Object
  (`mrbbc_def`). A class has its own list of methods, newest first, so a redefinition wins; the lookup for a self call
  (`mrbbc_find`) is self's class, then Object, and for an explicit receiver (`mrbbc_find_send`) the receiver's class only.
- `GETCONST a b` (`mrbbc_getconst`): the class named Syms[b] (any class of the program, by its plain name, so a nested
  class is also found from anywhere); an unknown name is `NameError` (`uninitialized constant NAME`).
- `SEND0`, `SEND` and `SENDB` with an explicit receiver: when the program defines the name in a class, one branch per
  method of the module is taken for the id `mrbbc_find_send` returns (the receiver's class's method, with its arity
  checked); otherwise the builtin of the name runs (`new`, the SEND0 methods and the binary methods), and a name none of
  those has is NoMethodError (`undefined method 'NAME' for CLASS`). A name only a top-level def defines is refused (it is
  private in mruby, and that error is not reproduced).
- `new` (`SEND0` or `SEND` of a class): `mrbbc_alloc` makes the instance (an object of the class, its ivars empty), its
  `initialize` runs with the arguments (`mrbbc_find_init`: when the class has none, no argument is allowed and the
  message is mruby's ArgumentError), and the instance is the value.
- `GETIV a b` and `SETIV a b` (`mrbbc_getiv`, `mrbbc_setiv`): self's instance variable Syms[b] (an object or a class; nil
  for an unset one). In the main program self is not modelled, so the top level's ivars are refused.
- Operators (`+ - * / == < <= > >=`) that the program defines in a class are refused: the fast path does not dispatch. A
  `to_s` the program defines in a class is refused for `STRCAT` for the same reason.
- Instances print nothing that matches mruby (`inspect` and `to_s` of an instance are NotImplementedError: mruby prints
  an address). A class prints its name, as `p` does.

### Blocks

A block is a child irep that a `BLOCK` names. Its body is a function `mrb_b<N>(MV *ret, MV *argv, long argc, MV *frame)`
(numbered over the module like the methods). `frame` is the frame of the function that executed the BLOCK: its registers
are the block's outer locals.

- `BLOCK a b` fills a 32-byte closure in a slot of the caller's frame (`mrbbc_block`: the block number, a copy of R(0)
  as self, the frame), and R[a] is the closure's address with the BLK tag (7).
- `SSENDB a b c` is a self call with the block R[a+n+1] (see "Methods"; `blk` is that register, or nil for SSEND).
- `BLKPUSH a b` in a method copies the method's block into R[a] (`mrbbc_blk_load`: a nil block raises
  `unexpected yield (LocalJumpError)`, as vm.c does). `block_given?`, a self call to the Kernel method with no arguments
  that the program does not define, is `false` at the top level, `block_given?` of the method's own block in a method,
  and refused in a block.
- `BLKCALL a b` (yield with b arguments in R[a+1..a+b]): argv[0] is the closure's self and the arguments follow; the
  block number picks the function, as the method number does for a self call.
- The block's prologue copies its required parameters from argv[1..] when argc gives them, else nil (a proc takes what it
  is given). With two or more parameters, a yield of one array argument is splatted instead (`mrbbc_splats`: argc 1 and
  an array; `mrbbc_ary_elt` gives element i, nil past its end), as mruby does for a block.
- `BREAK a` in a block (`mrbbc_break`, home = `%3`, the frame that made the block): the call that the block was passed to
  returns R[a]. The call is the `SENDB` or `SSENDB` in the frame that executed the `BLOCK`, and it is the only call on the
  stack from that frame, so the pending break is taken there (`mrbbc_break_take`): the value goes to the call's register
  and the code goes on after the call (`emit_block_site`). Calls on the way (the yielding method, the blocks between)
  return at once, as for a return, since their home is not the break's. A break from a block of the top level is the same
  mechanism (the main program's frame is the home).
- `GETUPVAR a b 0` and `SETUPVAR a b 0` read and write register b of the frame the block was made in. Level 0 only: a
  deeper level needs the frame's own link to its parent, which is not lowered.
- `RETURN` in a block is a local return (`next`).
- `RETURN_BLK` (a `return` that leaves the block, to the method the block was made in) makes the value the pending return
  of the block's home and returns the block. The home is a closure field: the frame of the method (or of the block's
  creator, for a block in a block), passed to a block as its `%4` parameter. The runtime keeps one pending return
  (`mrbbc_return_block`). After every method or block call in a method or a block, the function checks it
  (`mrbbc_unwinding`) and, if one is pending, `mrbbc_unwind_take` gives the value to its own `ret` when its frame is the
  home, and the function returns either way, so the return passes up the calls until the home takes it.
- A `return` from a block made at the top level is refused. In mruby it ends the script without printing anything (the
  value a value program prints would be the producer's, not mruby's), so it is not lowered.
- A pending return that no frame takes is impossible in this subset: a block is only yielded during the call of the
  method it is passed to, so its home is on the stack while the block runs.

Lifetime: a closure is valid while its frame is alive. A block is passed to a method and yielded there, and the program
has no way to keep it (a block parameter is refused), so no closure outlives its frame. This is the producer's reading,
and a program that kept a block would make the closure dangle.

Refused by name (exit 3, `refused: opcode NAME is not lowered yet (pc N)`): every other opcode, the `EXT1`-`EXT3`
prefixes and the instructions they widen, `LOADL` of a non-integer (`LOADL` never holds a string: mruby compiles a
string literal to `STRING`), and a main program with a catch table. In particular `SENDB` of a name the program does not
define in a class (a block call to a builtin), `RETURN_BLK` from a block of the top level (see below), `BREAK` outside a
block, `GETUPVAR`/`SETUPVAR` at level 1 or more, `BLKPUSH` of a block other than the method's own (a yield inside a
block), a method call with a keyword argument, any other method name, `AREF`/`ASET` (the destructuring of `a, b = x`),
`APOST`, `ARYCAT`/`ARYSPLAT` (a splat), `SYMBOL` (a quoted symbol) and `LOADSYM` of a name that is not plain (`:"a b"`,
`:+`), a float, a global variable, an instance variable of the main program, `RETSELF` of the main program, `TCLASS` and
`CLASS` in a method or a block, a method or block with parameters other than required ones, a method definition whose
name is not plain, a `def` inside a method or a block, an operator the program defines in a class, and `ENTER` with such
parameters are refused.

### The printed result

The value a program prints is the value its `RETURN` returns, which mruby compiles from the last expression of the
top level. The reference is the pinned mruby on the same file with the last line replaced by `p(<that line>)`, so each
value program ends in one expression on one line. The driver prints the value the way `p` does: nil, true, false, the
decimal integer, a string as its `inspect` (the named escapes, `\#` before `#{`, `#$` and `#@`, and `\xHH` for any other
byte outside printable ASCII), a symbol as `:name`, and an array as `[e1, e2]` with the same rule for each element.

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
| integer `<` (and the other comparisons) with nil, true, false, a string, an array or a symbol | `comparison of Integer with NilClass failed` (ArgumentError); the class name, as `comparison of Integer with String failed` |
| integer `+` or `-` with a string, an array or a symbol | `String cannot be converted to Float` (TypeError); the class name |
| integer `*` or `/` with nil, true or false | `can't convert nil into Integer`, `can't convert true into Integer` (TypeError) |
| integer `*` or `/` with a string, an array or a symbol | `can't convert String into Integer` (TypeError) |
| string `+` with anything but a string | `Integer cannot be converted to String` (TypeError); nil, true and false by their names: `nil cannot be converted to String` |
| string `*` with a negative integer | `negative argument` (ArgumentError) |
| string `*` with a non-integer | `nil cannot be converted to Integer` (TypeError); a class name otherwise: `Array cannot be converted to Integer` |
| string `<` (and the other comparisons) with anything but a string | `comparison of String with NilClass failed` (ArgumentError) |
| string `-` and `/` | `undefined method '-' for String` (NoMethodError) |
| array `+` with anything but an array | `nil cannot be converted to Array` (TypeError); `Integer cannot be converted to Array` |
| array `/` and the comparisons | `undefined method '/' for Array` (NoMethodError) |
| symbol `+` and the other arithmetic | `undefined method '+' for Symbol` (NoMethodError) |
| symbol `<` (and the other comparisons) with a non-symbol | `comparison of Symbol with Integer failed` (ArgumentError) |
| `[]` on nil, true, false or an integer | `undefined method '[]' for NilClass` (NoMethodError) |
| `[]=` (SETIDX) with a negative index below the start of an array | `index -3 out of array` (IndexError) |
| `size` or `length` on nil, true or false, and `length` on an integer | `undefined method 'size' for NilClass` (NoMethodError) |

`==` never raises on these values.

Messages the runtime does not reproduce as mruby does are not in the table: an integer overflow (see the deviations),
`Array#-` and `Array#*`, indexing or assignment with a range, and `String#[]=`. Those exit with a `NotImplementedError`
whose message says so, never with a value.

## Deviations from mruby

- **Integer overflow.** mruby promotes an overflowing `+ - *` (and `INT_MIN / -1`) to a Bignum or a Float. The inline
  path traps (the IR's checked operations abort, SIGABRT); the runtime path raises `NotImplementedError`. The corpus
  avoids overflow. Values up to 2^63 - 1 are exact.
- **Integer width.** This build uses mruby's default word boxing (`MRB_WORD_BOXING`), so its immediate integers are
  narrower than 64 bits and larger values are heap objects. The producer uses 64-bit integers throughout. The corpus
  stays within the immediate range, so the comparison with mruby does not test that boundary.
- **Refusals in place of silence.** Everything outside the subset is refused at lowering time, never compiled to a
  wrong value. The runtime's own gaps (listed above) are loud: a `NotImplementedError`, not a value.
- **Nested class names.** A nested class (`class A; class B`) is found by its plain name from anywhere, as
  `GETCONST` does. mruby finds `B` only inside `A` (and `A::B` needs `GETMCNST`, which is refused), so a program that
  names `B` at the top level is an error in mruby and a value here. `inspect` of a nested class prints `A::B`, as mruby.
- **No garbage collector.** Strings, arrays and symbols are never freed. A program that builds a lot of them uses memory
  without bound; the test programs are small.
- **Strings are bytes.** This build of mruby has no UTF-8 character handling: `size`, `length` and `[]` count bytes
  (`"é".size` is 2), and `inspect` escapes the bytes of a non-ASCII character as `\xHH`. The runtime does the same.
- **Recursion.** An array that contains itself inspects as `[...]`, as mruby does. Comparing two such arrays with `==`
  is not guarded and can overflow the C stack.

## Tests

- Reader (`tests/mrbbc/reader/run.sh`): 6 corpus programs and one generated program with registers past 255 (EXT1),
  each compiled four ways (default, `-g`, `--remove-lv`, `-g --remove-lv`): 28 files read by `mrbbc_dump` (every
  instruction decodes, no bytes after END) and run to status 0 by the pinned mruby. 15 malformed files (truncations,
  an extra byte, a wrong magic, format 03.00, an unknown section, an opcode out of range) are refused with status 1.
- Lowering (`tests/mrbbc/lower/run.sh`): 91 value programs match mruby's `p` (two generated: 200 locals, and an
  array literal of 130 elements, which mrbc builds with `ARYPUSH`; the `meth_*.rb` ones cover methods: zero and two
  arguments, self calls between methods, recursion, redefinition, a loop, `return`, and a `def` value; the `blk_*.rb`
  ones cover blocks: yield with and without arguments, a block that sets an outer local, `block_given?`, a loop of
  yields, a block inside a block, a block that calls a method, and `return` out of a block through one or two
  methods); the round 4 ones cover classes (`cls_*.rb`: `new` with and without `initialize`, instance variables, two
  classes with one method name, reopening, a self call from a method, objects passed as arguments, a nested class, a
  loop of method calls, identity, and a class as a value) and break (`blk_break*.rb`, `sendb_*.rb`: from a yield, to the
  innermost call, nested blocks, from a `while` loop in the yielding method, a `SENDB` on an object, and from a
  `SSENDB` in a method), and `blk_splat*.rb` (two and three parameters). 31 runtime errors match mruby's last stderr
  line and status 1 (9 from round 1, 13 from round 2, 4 in round 3: method arity, call before def, and yield without a
  block; 5 in round 4: an instance's method arity, an undefined method of a class, `new` with an argument and no
  `initialize`, an undefined constant, and a method called before its `def` runs); 23 programs are refused with status 3,
  a `refused:` message and no stdout: 22 in `err/` and a generated one with EXT1 prefixes. `err/` is the refusal set, `rterr/` the runtime errors; the brief's "err/ programs must be
  refused" is read as the first.

Round 2 (strings, arrays, SEND0 and SEND of the core methods) is in the tables above. Round 3 lowers methods (see
"Methods": `def` of a method with required parameters, self calls to the program's methods) and blocks (see "Blocks":
`BLOCK`, `SSENDB`, `BLKPUSH`, `BLKCALL`, `GETUPVAR` and `SETUPVAR` at level 0, `block_given?`, and `RETURN_BLK` out of a
block whose home is a method). Round 4 lowers classes (see "Classes") and `BREAK` (see "Blocks"), `SENDB` with an
explicit receiver of a program-defined method, and blocks with two or more parameters. Still refused: `RETURN_BLK` from
a block of the top level, yields and variables more than one level out, `SENDB` of a builtin method, keyword arguments,
optional or rest parameters, `AREF`/`ASET`, `APOST`, splats, the quoted symbols, a superclass (a run-time error), the
operators and `to_s` that a class defines, and the instance variables of the top level. The strings and arrays in the
subset are the ones the examples above name; `Array#-` and `Array#*`, `String#[]=`, ranges as indexes and the other
methods of the core classes are not in it.

## Open questions

- The brief names `LOADI`; mruby 4.0.0 has no such opcode. The integer loads are `LOADI__1`, `LOADI_0`..`LOADI_7`,
  `LOADI8`, `LOADINEG`, `LOADI16`, `LOADI32` and `LOADL` (the pool), all lowered.
- The IR gained no form: the producer uses the existing forms (`let`, `slot`, `offset`, `load`, `store`, `copy`,
  `cadd`, `csub`, `cmul`, `lt.s`, `le.s`, `lt.u`, `le.u`, `eq`, `if`, `goto`, `label`, `return`, `call` under `eval`).
- `__nfcxx_smul64_ovf` is needed by the emitter's checked 64-bit multiply and is defined in `be/nfcxx_ldrt.c`. The
  runtime here defines the same one-line function rather than linking the shared runtime.
- The reader's DBG section is read for its size and dropped; line information is not used yet, so runtime errors print
  the program name where mruby prints `file:line`.
- The brief named `LOADL` and `LOADSYM` for strings. In mruby 4.0 a string literal is `STRING` (a pool string), and `LOADL`
  holds only numbers; `LOADSYM` is the symbol literal. Round 2 lowers `STRING` and `LOADSYM` (plain names only).
- `ARYDUP` is not an opcode of mruby 4.0 (`ops.h` has no such entry); array literals are `ARRAY`, `ARRAY2` and
  `ARYPUSH`, and the brief's `ARYDUP` is not needed.
- `AREF` and `ASET` (the destructuring of `a, b = x`) are refused; `GETIDX`, `GETIDX0` and `SETIDX` are the indexing
  opcodes of mruby 4.0 (the brief's OP_GETIDX/OP_SETIDX).
