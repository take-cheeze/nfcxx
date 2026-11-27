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

`mrbbc_lower --report-all program.rite` writes no IR and lists every refusal of the program, one per line
(`<function> (<method>): refused: ...`), instead of stopping at the first, and on stderr how many functions have one; it
exits 3 when there is any. It is the census of what a larger program still needs.

## bc2cpp backend

bc2cpp can send its usual `mrbc_rb` bytecode to this producer instead of emitting C++:

```sh
scripts/setup-mrbbc.sh
scripts/setup-qbe.sh
mkdir -p build/ruby-app
OUT_DIR=build/ruby-app OUT_SYMBOL=app \
  bundle exec ruby bc2cpp/tools/bc2cpp/bc2cpp.rb --backend=mrbbc app.rb > build/ruby-app/app.ir
bundle exec ruby scripts/pathb-qbe-emit.rb build/ruby-app/app.ir > build/ruby-app/app.ssa
build/qbe/qbe build/ruby-app/app.ssa > build/ruby-app/app.s
cc -std=c99 -DMRBBC_VALUE=8 build/ruby-app/app.s \
  tests/mrbbc/runtime/mrbrt.c tests/mrbbc/runtime/driver.c -o build/ruby-app/app
build/ruby-app/app
```

The command writes Path B IR to stdout and keeps `app.mrb` in `OUT_DIR`. With no `OUT_DIR` or `OUT_SYMBOL`, these
default to the first input's directory and its sanitized basename, as in the C++ path. Pass multiple Ruby files in
load order to compile one complete program. The runtime driver prints the program's final value, as the lowerer
suite does. `--backend=cpp` explicitly selects the existing default C++ output.

`--mrbbc-value=8|4|16` selects the value layout (default 8); compile `mrbrt.c` and `driver.c` with the matching
`MRBBC_VALUE`. `BC2CPP_MRBBC_LOWER` selects a lowerer executable path instead of `build/mrbbc/mrbbc_lower`.
`scripts/setup-mrbbc.sh` builds that executable with `CXX` (default `c++`) and replaces it only after a successful
build. The usual `MRBC`, `BC2CPP_NO_MRBC` and `BC2CPP_MRBC_RB` controls still select bytecode compilation and
verification. The standalone backend dispatches before loading the C++ world's signatures and inference passes.

This backend uses mrbbc's standalone runtime and supported subset, described below. C++ gem metadata, native/outside
source lists, owner filtering, type-check-only mode and self-registration are rejected: supply the complete Ruby
program as source arguments. It accepts neither C++ output switches such as `--annotated` nor shared-unit plans.
The fork's `FSTRING` opcode (frozen string literals) is explicitly refused until mrbbc supports those semantics.
Other unsupported constructs retain mrbbc's `refused:` diagnostic and status 3. A failed lowering writes no IR to
stdout, even if an alternate lowerer printed partial output; option errors exit 2 and missing tools or I/O errors
exit 1. The bytecode artifact may remain after a refusal.

`bundle exec ruby tests/bc2cpp/mrbbc_backend.rb` checks this route, including runtime execution through QBE in all
three layouts, multi-file classes and blocks under GC stress, frontend controls and atomic refusal. It requires the
two setup commands above (or `BC2CPP_MRBBC_LOWER` and `QBE` paths); it uses no C mrbc or reference interpreter.

The unmodified `scripts/nfcxx-state.rb` can be compiled with a separate entry harness:

```sh
mkdir -p build/driver-state
OUT_DIR=build/driver-state OUT_SYMBOL=state \
  bundle exec ruby bc2cpp/tools/bc2cpp/bc2cpp.rb --backend=mrbbc \
  scripts/nfcxx-state.rb tests/mrbbc/nfcxx/state_entry.rb > build/driver-state/state.ir
```

Emit and link this IR with the same QBE/runtime commands above. The harness exercises `names`, first-match and missing
`get`, shared value arrays, and NUL-delimited `records`; CI compares these with Ruby in all three layouts under GC stress.
The full nfcxx command-line driver still needs modules, general constants/globals, requires, and further host APIs.

### Optional libuv host runtime

For language-independent boxed argument frames and explicit typed integer exports, see
[`pathb-call.md`](pathb-call.md). That interface does not depend on the hosted adapter below.

The standalone runtime also has an optional hosted build, enabled with `MRBBC_LIBUV=1`. It lowers `ARGV`, `$0`/
`$PROGRAM_NAME`, `$stdin`/`$stdout`/`$stderr` (and `STDIN`/`STDOUT`/`STDERR`), standard-stream `read` without a length,
standard-stream `write(string)`, `File.read(path)`, `File.write(path, string)`, `File.exist?`, `File.file?`,
`File.directory?`, `File.executable?` and `Dir.exist?`. Reads and writes preserve binary bytes. `ARGV` is one shared,
mutable, rooted array; custom embedding drivers supply the borrowed process arguments with `mrbbc_set_args` before
`mrbbc_run`. `ARGV` and the program-name globals do not require libuv.

For example, compile the unchanged state library with an entry that consumes process arguments and binary stdin,
writes records to the file named by its first argument, copies them to stdout, and reports checks on stderr:

```sh
# Install libuv's development files and pkg-config (Ubuntu: libuv1-dev pkg-config).
mkdir -p build/driver-state-io
OUT_DIR=build/driver-state-io OUT_SYMBOL=state \
  bundle exec ruby bc2cpp/tools/bc2cpp/bc2cpp.rb --backend=mrbbc \
  scripts/nfcxx-state.rb tests/mrbbc/nfcxx/state_io_entry.rb > build/driver-state-io/state.ir
bundle exec ruby scripts/pathb-qbe-emit.rb build/driver-state-io/state.ir > build/driver-state-io/state.ssa
build/qbe/qbe build/driver-state-io/state.ssa > build/driver-state-io/state.s
cc -std=c99 -DMRBBC_VALUE=8 -DMRBBC_LIBUV=1 build/driver-state-io/state.s \
  tests/mrbbc/runtime/mrbrt.c tests/mrbbc/runtime/mrbrt_uv.c tests/mrbbc/runtime/uv_driver.c \
  $(pkg-config --cflags --libs libuv) -o build/driver-state-io/state
printf 'input\000bytes' | build/driver-state-io/state build/driver-state-io/records . example
```

`uv_driver.c` lets the program own stdout; the test driver `driver.c` instead prints its final expression. The adapter uses
libuv's synchronous filesystem API (NULL callbacks), cleans every request, handles partial writes and closes files it
opens on success or I/O failure. Standard descriptors are borrowed and never closed by the adapter. No callback or
event loop retains a Ruby value. OS failures raise an `Errno::NAME` error with libuv's platform message; messages need
not match mruby's libc formatting. The existing runtime error path still terminates the process rather than rescuing.

The libuv dependency is optional: ordinary runtime builds and embedded targets need neither its headers nor its library;
host calls there fail explicitly with `NotImplementedError`. Length/offset/keyword forms, File/IO handle construction,
custom String/path coercion, environment access, process spawning, dynamic requires, and general globals remain
unsupported. This is a host I/O foundation, not full CLI compilation or asynchronous Ruby I/O.

`bundle exec ruby tests/bc2cpp/mrbbc_uv.rb` compares the actual state-library scenario and stream operations against Ruby
in byte mode, for all three layouts with GC stress; it also checks I/O errors and refusal without the optional adapter.

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
  and both 16-bit for EXT3). `mrbc` uses a prefix when a register, a symbol, a pool entry or a child is past 255. The
  lowering takes the widened instruction as it takes the narrow one.

`mrb::decode_iseq` throws on an opcode out of range, a prefix with no instruction after it, or an instruction that runs
past the iseq. The reader checks every section size and the record sizes, rejects bytes after END, and rejects a
DBG or LVAR section before IREP.

## The lowering

### Values and registers

A register R(i) is a slot `r<i>` of type `MV`, in one of three layouts (`mrbbc_lower --value=N`, and the runtime built
with `-DMRBBC_VALUE=N`; `tests/mrbbc/lower/run.sh` takes `MRBBC_VALUE`):

| Layout | Register | Encoding |
| --- | --- | --- |
| `8` (default) | a 64-bit word | an integer in -2^62..2^62-1 is `(i << 1) \| 1`; a symbol `(index << 2) \| 2`; nil, false, true are 0, 4, 12; any other word is the address of an object whose header gives its tag |
| `4` | a 32-bit word | the same, with small integers in -2^30..2^30-1; on a 64-bit host the objects come from an arena mapped below 2 GB (`MAP_32BIT`, x86-64 Linux) |
| `16` | tag byte + int64 | the tag at offset 0 (the runtime's tags, `mrbrt.h`), the int64 or the object's address at offset 8 |

Integers are exact to 64 bits in every layout: one outside the small range is a boxed integer, an object of the heap. Past
64 bits the runtime raises `NotImplementedError` (see the deviations). A symbol is the index of its interned name. The
objects (strings, arrays, hashes, instances, closures, boxed integers) are allocated by the runtime's collector (mark and
sweep, mrbrt.c, "the collector"), and freed when they are unreachable. The main program becomes one IR function
`mrb_irep_0(MV *ret)`. A `RETURN` copies R(a) into `*ret`, and the driver prints `*ret` the way `p` does. A copy of a
register is a load and a store of its word (two for the 16-byte layout), not the IR's `copy`, which the emitter makes a
`memmove` call.

Integer operators have an inline fast path when every operand is a small integer. In a word layout, `<`, `<=`, `>`, `>=`
compare the words (the tagging keeps the order); `+`, `-` and `*` shift the integers out, compute with wrapping
operations (`*` only for factors of at most half the word, so the product cannot wrap) and store the result when it is in
the small range. Otherwise `mrbbc_binop` runs, which boxes a larger result. In the 16-byte layout `+`, `-` and `*` are the
IR's checked `cadd`, `csub` and `cmul` (they trap on overflow). Everything else calls `mrbbc_binop`, which does the rest of
mruby's rules for integers, strings, arrays and symbols (`==` compares contents: strings by bytes, arrays element by
element).

The collector's roots are precise. Each function's slots (argument vectors, temporaries) are placed in its frame after the
registers, and the function registers the whole frame on entry (`mrbbc_gc_enter`, which sets it to nil) and takes it off
before each `(return)` (`mrbbc_gc_leave`); the record is a 32-byte slot `gcf`. The argument vector of a splat call, held
only in an IR register, is pinned to the caller's frame until its next splat call or its return. A runtime helper that
holds a new value in a C local across an allocation protects it (`gc_protect`). `-DMRBBC_GC_CONSERVATIVE=1` scans the C
stack instead (and keeps a set of object addresses to check its words against).

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
| Classes | `CLASS` (defines or reopens a class, with the superclass R[a+1] when it is not nil), `EXEC` (runs a class body with self R[a]), `TCLASS` (the class a def goes to), `GETCONST` (a class by its name, or Object), `GETIV` and `SETIV` (an instance variable of self), `RETSELF` (in a method, a block or a class body); see "Classes" |
| Super | `SUPER a b` (the method of the superclass of the method's own class), `ARGARY` (the arguments of a zsuper: the method's required and optional parameters, read in a method or in a block that a method makes); see "Super" |
| Break | `BREAK` (from a block, to the call the block was passed to); see "Blocks" |
| Blocks | `BLOCK` (a block made from child b, closed over this frame), `BLKPUSH` (the method's own block, in a method), `BLKCALL` (yield), `GETUPVAR` and `SETUPVAR` at level 0 (the frame the block was made in); see "Blocks" |
| Parameters | `ENTER` with required, optional, rest and post parameters and keyword parameters (in a method or a block, at pc 0; `mrbbc_bind` fills them as vm.c's ENTER does, and the jump ENTER picks sets the optional ones' defaults; a block may have two or more); `KEY_P`, `KARG`, `KEYEND` and `HASH` (the keyword hash); see "Parameters" |

The method table. A `SEND0` or `SEND` (with `c` = n | k<<4, so n = 0 or 1 and k = 0) names its method by a symbol. A
method outside the table is refused at lowering time with `refused: SEND0 of method 'NAME' is not lowered yet (pc N)`:

| Method | Receiver and result |
| --- | --- |
| `to_s` | integer, nil, true, false, symbol, string (itself), array (its inspect) |
| `size`, `length` | string and array (byte count and length); symbol (its name's length); `size` of an integer is 8, as `sizeof(mrb_int)` |
| `!` | any value: true for nil and false |
| `+ - * / == != < <= > >=` (one argument) | the binop helper, as the opcode |
| `<<` (one argument) | appends an element to an array, or a String/byte integer (0..255) to a string; returns the same receiver |
| `first` (no argument) | the first array element, or nil |
| `join` (no argument) | array elements joined with no separator; nested arrays are flattened and other elements use `to_s`, as mruby does |
| `map`, `find`, `each` (no argument, explicit block) | array iteration; `find` returns the original matching element or nil, `each` returns the receiver |

Append preserves aliases of strings and arrays. Hash insertion snapshots String keys, so appending to a key's original
alias does not rename the stored entry. Iterators read the array's current length each turn, preserve destructuring,
and propagate `break` and nonlocal `return`. The receiver, block, result and callback arguments remain GC roots across
callbacks. Program-defined methods of these names retain their normal dispatch ahead of the builtin fallback.

### Methods

A method is a child irep that a `TDEF` names. Each such body is a function of its own,
`mrb_m<N>(MV *ret, MV *argv, MV *blk, long argc)`, numbered over the module in the order the TDEFs are found (the main
program is `mrb_irep_0`, as before). `argv[0]` is self and `argv[1..argc]` are the arguments the call gave: the prologue
copies them into R(1)..R(n), n the method's required and optional parameters, and sets the other registers to nil. `argc`
is the count at the call site (a constant of the SEND, or the count of a runtime call), which the optional parameters need.
`blk` is the block the call gave, or a nil value. The signature gained a `kw` argument (`long`, 1 when the call gave
keyword arguments; the hash is then `argv[argc+1]`; `%4`). A method's ENTER must be its first instruction and must not have
a block parameter (bit 0); `**` (aspec bit 1) and `&nil` (bit 23) are lowered, and any other parameter is too. A block
with a `**` or `&nil` parameter is refused.

Parameters (vm.c's ENTER, mruby 4.0's layout): the required, optional, rest and post parameters fill R(1..len) in that
order (len = req+opt+rest+post); with keyword parameters the keyword hash is R(len+1); the block slot is R(len+kd+1). The
prologue calls `mrbbc_bind(R(1), argv, argc, kw, m1, o, r, m2, kd, strict)`, which writes those registers the way vm.c's
ENTER does (missing required ones are nil; the rest is an array of the middle arguments; the post ones are the last m2;
for a block, one array argument is splatted when it takes two or more) and returns the count of optional parameters given,
which the jumps choose the defaults by. A keyword hash given to a method without keyword parameters is a positional
argument (vm.c's rule, also in the arity count). The arity error is `wrong number of arguments (given N, expected M)` with
M = required + post (vm.c's `argnum_error(m1+m2)`). Its N follows vm.c's `argnum_error`, which reads `ci->n`: a body with
required parameters only counts the positional arguments (the keyword hash only when there are none), a body with keyword
parameters counts the positional arguments (the same exception), and any other body (optional, rest or post parameters)
counts the keyword hash as a positional argument (`rterr/kw_positional_arity.rb`, `kw_kd_noargs.rb`, `kw_opt_count.rb`). A call with keyword arguments
builds the hash from its pairs at R[a+n+1..] (`mrbbc_hash_new`, `mrbbc_hash_set`) and passes it as `argv[n+1]`. A
missing keyword is `missing keyword: NAME` (ArgumentError, from KARG), and a keyword the method does not take is
`unknown keyword: NAME` (from KEYEND, after the body's keywords are taken). A block with keyword parameters gets an empty
hash (a yield gives no keywords). Keyword defaults may refer to positional parameters, not to other keywords (mruby 4.0
says `undefined method`, and the producer refuses such a call: `err/kw_default_kw.rb`).

A `**` parameter is the keyword hash itself (R(len+1), the `kd` of the prologue), so its local needs no move; the keyword
parameters take their keys out of it (`KARG`), as vm.c does. A `&nil` parameter makes a block given to the method an
ArgumentError `no block accepted` on entry (`mrbbc_noblock`). A `**h` splat in a call is built as vm.c's codegen builds
it: `HASH` (an empty hash), then `HASHCAT` (`mrbbc_hash_cat`: the pairs of a hash, later keys winning; nil or another
value is a TypeError, and a program that defines `to_hash` is refused, since mruby would convert other objects with it),
then the `HASHADD` of the pairs after it. The call's keyword flag is `mrbbc_kw_flag`: 1 when the hash has a key, 2 when it
is empty. A flag of 2 is a positional hash only for a method of only required parameters (vm.c's ENTER fast path, the
TDEF's flag bit 1; `mrbbc_bind` and `check_arity` take it so), and nothing for the others: `one(**{})` binds `{}` to
`def one(x)`, while `def m(a, b = 1)` gets no hash.

Optional parameters (vm.c's `ENTER`, `ci->pc += ...`): after ENTER come n+1 JMPs, the one at index k for k optional
arguments given (k = argc - required, clamped to 0..n), and the last one jumps past all the defaults. The producer's
ENTER is a dispatch on argc: it jumps to the JMP of index k, which goes to the default of optional k (the defaults follow
the JMPs, in order, then the body). An arity error is the count outside required..required+optional, with mruby's message
that names the required count (`expected 1` for `def f(a, b = 1)`, as vm.c's ENTER gives it).

Frames: every function keeps its registers in one contiguous slot, `frame`, of 16 bytes per register, and R(i) is the
register number 4 + i of the IR (the emitter names registers by digits only). The frame's address is what a BLOCK stores
for its closure.

- `TDEF a b c` calls `mrbbc_def(name, N, m)`, which adds the method to the runtime's table (Object, the only class
  a program of this subset defines methods on), then R[a] = the symbol, as `vm.c` sets it. A redefinition wins.
- `SSEND0 a b`, `SSEND a b c` and `SSENDB a b c` (self's method, with `n` = c arguments): the arguments R[a+1..a+n] are
  copied into a vector of their own, self first. `mrbbc_find(name, n)` returns the number of the latest definition of
  the name, or raises. The call is then one branch per method of the module with that name (the runtime only gives
  numbers a def of the name registered): `if id == N then mrb_m<N>(&R[a], argv, blk)`, where blk is R[a+n+1] for SSENDB and a nil slot otherwise. A method's return writes R[a] through `ret`, so the
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
  self, else at the top level. A class of the name that exists is reopened. A new class's superclass is R[a+1] (a class,
  or Object when it is nil). A reopened class must have that superclass, else `superclass mismatch for NAME` (TypeError);
  a superclass that is not a class is `superclass must be a Class (V given)` (TypeError). The names of the core classes
  are refused (NotImplementedError at run time), except Object, which GETCONST gives as the root class.
- Method lookup walks the superclass chain: the class of the receiver, its superclass, ..., Object last (`find_chain`).
  A self call (`mrbbc_find`), an explicit receiver (`mrbbc_find_send`) and the initialize of `new` (`mrbbc_find_init`) all
  use it. An explicit receiver that reaches a top-level def (Object's, private in mruby) is a NoMethodError.
- `TCLASS a`: R[a] = Object at the top level, the class body's self in a class body (a method or a block is refused).
- `TCLASS a; METHOD a+1 c; DEF a b` is mrbc's def of a body past child 255 (TDEF has one byte for c), lowered as `TDEF a b c`.
  `METHOD` and `DEF` in any other sequence are refused.
- `attr_reader`, `attr_writer` and `attr_accessor` of literal symbols in a class body define one generated method per
  accessor on the class (`mrbbc_def_in`, 0 or 1 argument), which reads or sets the instance variable; the call gives nil.
  Any other argument is refused.
- `EXEC a b`: runs class body b with self R[a] and R[a] = its value (`mrb_k<N>`, called directly: the child is static).
- `TDEF` in a class body defines the method on that class (`mrbbc_def_in` with self), at the top level on Object
  (`mrbbc_def`). A class has its own list of methods, newest first, so a redefinition wins; the lookup for a self call
  (`mrbbc_find`) is self's class, then Object, and for an explicit receiver (`mrbbc_find_send`) the receiver's class only.
- `GETCONST a b` (`mrbbc_getconst`): the class named Syms[b] (any class of the program, by its plain name, so a nested
  class is also found from anywhere); an unknown name is `NameError` (`uninitialized constant NAME`).
- `SEND0`, `SEND` and `SENDB` with an explicit receiver: when the program defines the name in a class, one branch per
  method of the name is taken for the id `mrbbc_find_send` returns (the receiver's class's method, with its arity
  checked); otherwise the builtin of the name runs (`new`, the SEND0 methods and the binary methods), and a name none of
  those has is NoMethodError (`undefined method 'NAME' for CLASS`). A name only a top-level def defines is refused (it is
  private in mruby, and that error is not reproduced).
- `new` (`SEND0` or `SEND` of a class): `mrbbc_alloc` makes the instance (an object of the class, its ivars empty), its
  `initialize` runs with the arguments (`mrbbc_find_init`: when the class has none, no argument is allowed and the
  message is mruby's ArgumentError), and the instance is the value.
- `GETIV a b` and `SETIV a b` (`mrbbc_getiv`, `mrbbc_setiv`): self's instance variable Syms[b] (an object or a class; nil
  for an unset one). In the main program self is not modelled, so the top level's ivars are refused.
- A class prints its name, as `p` does. The printing of instances is in "Operators, to_s and inspect" below.

### Super

`SUPER a b` (`super` in a method): R[a] = the method of the superclass of the class the current method is defined in,
called on self R(0). `mrbbc_find_super` looks from `owners[N]`, the class the TDEF of method N named (Object for a
top-level def, recorded by `mrbbc_def` and `mrbbc_def_in`), through the superclass chain of that class. The arguments are
R[a+1..a+n] (b = n) and the block R[a+n+1], as `vm.c` takes them: a block of `super { }` or the method's own block
(`super` with no arguments in a method without parameters copies R(1), where the caller leaves the block).

- A zsuper (`super` with no arguments) of a method with parameters is `ARGARY` followed by `SUPER a 15`. Codegen puts the
  required and the optional parameters in ARGARY's count m1 (the method's `def f(a, b = 2)` gives m1 = 2). The producer
  lowers it when the SUPER directly follows the ARGARY (the count 15 is a splat otherwise, which is refused): the arguments
  are the method's R(1..m1), the current values of the parameters, as mruby passes them. A method's block is kept in
  R(m1+1) (the prologue writes it there), where ARGARY reads it. ARGARY with rest, post or keyword parameters is refused.
- A zsuper in a block that a method makes directly (level 1 of the ARGARY) reads the same values from the method's frame
  (the block's %3), and the block from the method's R(m1+1): the block sees the parameters as the method has them,
  including an assignment the block made to one of them, as mruby's shared environment does.
- When the superclass chain has no program method of the name: `initialize` is the builtin BasicObject#initialize, which
  takes no argument (ArgumentError otherwise) and gives nil; a builtin name of Object (`to_s`, `inspect`, `==`, ...) is a
  NotImplementedError (the builtin is not lowered); any other name is `super: no superclass method 'NAME' for CLASS`
  (NoMethodError).
- A `super` in a block is lowered with its arguments and an explicit block (or none). The owner is the method the block is
  made in (`block_method`, at any depth), so `super` in a block of a block finds the same superclass method. Two limits:
  the zsuper of a block made by a method is lowered (see above), and so is the zsuper of a block that a block of a method
  makes (ARGARY at level 2, which reads the method's parameters and block from the home frame: a block of the method's
  block passes the real block, as mruby does). A super with no explicit block in such a block passes nil: its implicit
  block is an upvar of level 2 past the method, which mruby reads as nil (see "Blocks"). Deeper blocks are refused.
- A `super` with a splat (`super(*a)`) or with keyword arguments (`super(a: 1)`, `super(x, k: 1) { }`) is lowered. A splat
  is the array in R[a+1] with count 15 (vm.c's `CALL_MAXARGS`): the producer's `mrbbc_splat_argv` builds the argument
  vector from it and `mrbbc_ary_len` gives the count, so a zsuper (the ARGARY's array) and an explicit splat share the path.
  A splat of keyword arguments (`**h`, k = 15) is lowered (see "Parameters"); a splat with keyword arguments (n = 15 and k) is refused.

### Operators, to_s and inspect

The operators (`+ - * / == != < <= > >=`, the opcodes and the SEND forms) and `to_s`, `inspect` of an instance of a
program class dispatch to the program's method of the name when the instance's class (or a superclass) has it. The
integer fast path is unchanged: both operands integers, the inline operation. Everything else calls `mrbbc_binop`, which
for an instance (`obj_op`) calls the method (`user_method`, the chain of the receiver's class), with the result of the
method as the value of the operator (mruby does not convert it, so `==` may give 5). Without the method, `==` and `!=` are
identity, or `!=` negates a `==` that the program defines (mruby's `BasicObject#!=`); the other operators are a
NoMethodError (`undefined method '+' for CLASS`). Only an instance has methods of the program (an integer, a string or
nil does not get a user method), so `1 == obj` is false, as mruby's Integer#== is.

- The runtime calls the program's methods through `mrbbc_user_call`, which the lowered module defines (one branch per
  method, as a self call has): `call_user(ret, id, recv, arg)`. An argument count that is wrong is an ArgumentError.
- `value_eq` (the `==` of arrays and of the operators) is identity first, then the instance's `==` (a truthy result is
  equal), as `rb_equal` does: `[P.new(1)] == [P.new(1)]` calls `P#==` on the elements.
- `STRCAT` (`"#{x}"`) and `to_s` (`SEND0`) of an instance call its `to_s`. A `to_s` that gives no string is mruby's
  default to_s (an address), which is not lowered (NotImplementedError).
- `p` of an instance (the driver's print, and an instance inside an array) calls its `inspect` and writes the string
  (its to_s, when the inspect gives something else). An instance without an `inspect` of the program prints mruby's
  default `#<Foo:0x...>`, which is not reproduced: NotImplementedError. So is the `to_s` of an instance without a
  program `to_s`.
- An operator the program defines at the top level (an Object method every value inherits) is refused: the runtime does
  not reach it for nil and the other values. A `def` of an operator name is lowered (its symbol prints as `:+`).

### Blocks

A block is a child irep that a `BLOCK` names. Its body is a function `mrb_b<N>(MV *ret, MV *argv, long argc, MV *frame)`
(numbered over the module like the methods). `frame` is the frame of the function that executed the BLOCK: its registers
are the block's outer locals.

`BLKCALL` and the runtime's array iterators use `mrbbc_yield`; it invokes the module's `mrbbc_user_yield` dispatcher
for a closure. Symbol blocks such as `map(&:first)` call a program-defined method or a supported zero-argument builtin
on the first yielded argument. Other dynamic Symbol calls raise `NotImplementedError`. Lowered modules now export
both `mrbbc_user_call` and `mrbbc_user_yield`; regenerate saved IR when updating the runtime.

- `BLOCK a b` fills a 32-byte closure in a slot of the caller's frame (`mrbbc_block`: the block number, a copy of R(0)
  as self, the frame), and R[a] is the closure's address with the BLK tag (7).
- `SSENDB a b c` is a self call with the block R[a+n+1] (see "Methods"; `blk` is that register, or nil for SSEND).
- `BLKPUSH a b` in a method copies the method's block into R[a] (`mrbbc_blk_load`: a nil block raises
  `unexpected yield (LocalJumpError)`, as vm.c does). `block_given?`, a self call to the Kernel method with no arguments
  that the program does not define, is `false` at the top level, `block_given?` of the method's own block in a method,
  and refused in a block.
- `BLKCALL a b` (yield with b arguments in R[a+1..a+b]): argv[0] is the closure's self and the arguments follow; the
  block number picks the function, as the method number does for a self call.
- The block's prologue takes its required and optional parameters from the arguments the yield gave (`mrbbc_block_arg`:
  argv[i] for i up to argc, nil past it, so a proc takes what it is given). With two or more parameters (required and
  optional together), a yield of one array argument is splatted instead, and the count is the array's length
  (`mrbbc_block_argc`), as mruby does for a block. The count then chooses the optional parameters' defaults, by the same
  dispatch on ENTER as a method's.
- `BREAK a` in a block (`mrbbc_break`, home = `%3`, the frame that made the block): the call that the block was passed to
  returns R[a]. The call is the `SENDB` or `SSENDB` in the frame that executed the `BLOCK`, and it is the only call on the
  stack from that frame, so the pending break is taken there (`mrbbc_break_take`): the value goes to the call's register
  and the code goes on after the call (`emit_block_site`). Calls on the way (the yielding method, the blocks between)
  return at once, as for a return, since their home is not the break's. A break from a block of the top level is the same
  mechanism (the main program's frame is the home).
- `GETUPVAR a b 0` and `SETUPVAR a b 0` read and write register b of the frame the block was made in. Level 0 only for a
  block made by a method, the main program or a class body (depth 1). A block made by a block (depth 2) reaches the frame
  its chain starts in at level 1: the home, `%4`, which BLOCK passes on (`frame_owner`). So `GETUPVAR a b 1` in such a
  block reads the method's, the main program's or the class body's register b, as vm.c's uvenv does (checked against the
  reference: a method's local, and a top-level local, set from a block in a block). The home's register must be one of its
  locals (below its `nlocals`), else refused. Level 2 from a depth-2 block is past that frame, nil for the block slot (see
  the next bullet); any other level 2 read of a depth-2 block is refused. A block made by a method
  reads level 1 as nil: the method's proc has no environment above it.
- Blocks nested three or more deep (round 8). The level counts the scopes out from the creator: level 0 is the frame the
  block was made in (`%3`), level 1 the creator's own creator, and so on up to the method or the main program (checked
  against the reference, `blk3_locals.rb`, `blk4_upvar.rb`). The closure keeps those frames in its `disp` array (`Clo`,
  `MRBBC_MAX_DEPTH` = 8): a block made by a block gets its creator's `%3` first and the creator's own `disp` after it
  (`mrbbc_block_nested`), and a block function takes its closure's `disp` as its `%5` parameter (`mrbbc_blk_disp` at the
  call). `GETUPVAR` and `SETUPVAR` at level L >= 1 of a block of depth 3 or more read the frame `disp[L-1]`
  (`mrbbc_upframe`), and the register must be a local of the body at that level (`upvar_body` walks the creators). A
  return out of such a block and a break from it use the home and the call frame as before (`blk3_return.rb`,
  `blk3_break.rb`). A block nested more than 8 deep is refused.
- `GETUPVAR a b 1` in a block that a method makes directly, with b = the method's parameters + 1 (its block slot R(n+1)), is nil. The
  compiler emits it for the implicit block of a `super` in the block (gen_blkmove), and mruby 4.0.0 reads nil there: the
  method's proc has no environment, so the upvar of level 1 is nil. Checked against the reference (`sup_blk_noblock.rb`:
  the method's block is not passed on, and `block_given?` of the superclass method is false). Any other level-1 read is
  refused.
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

Refused by name (exit 3, `refused: opcode NAME is not lowered yet (pc N)`): every other opcode, `LOADL` of a non-integer (`LOADL` never holds a string: mruby compiles a
string literal to `STRING`), and a main program with a catch table. In particular `SENDB` of a name the program does not
define in a class (a block call to a builtin), `RETURN_BLK` from a block of the top level (see below), `BREAK` outside a
block), `GETUPVAR`/`SETUPVAR` at level 1 or more outside the depth-2 cases above, `BLKPUSH` of a block other than the method's own (a yield inside a
block), any other method name, `ASET`,
`APOST`, `SYMBOL` (a quoted symbol) and `LOADSYM` of a name that is not plain (`:"a b"`,
`:+`), a float, a global variable, an instance variable of the main program, `RETSELF` of the main program, `TCLASS` and
`CLASS` in a method or a block, a method with a block parameter (`&b`), a block with a `**` or `&nil` parameter, a method definition
whose name is not plain and not an operator, a `def` inside a method or a block, an operator the program defines at the top
level, a splat of keyword arguments with a splat of arguments, `ARGARY` other than the parameters of a method (or of a block a method
makes, at level 1 or 2), with rest, post or keyword parameters, and `ENTER` with such parameters are refused. A keyword or
splat call to a builtin method (`first(n: 1)`, `new(*a)`) is refused.
`SUPER` and `ARGARY` outside a method (the main program, a class body, or a block of one) are not refused: vm.c raises
NoMethodError `super called outside of method` when they run, and so does the lowered code (`mrbbc_no_super`).

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

- **Integer overflow.** mruby promotes an integer past 64 bits (an overflowing `+ - *`, `INT_MIN / -1`) to a Bignum. The
  runtime raises `NotImplementedError` there (the 16-byte layout's inline path traps instead: the IR's checked
  operations abort). Values up to 2^63 - 1 are exact in every layout; `int_big.rb` crosses the small ranges of the word
  layouts.
- **Refusals in place of silence.** Everything outside the subset is refused at lowering time, never compiled to a
  wrong value. The runtime's own gaps (listed above) are loud: a `NotImplementedError`, not a value.
- **Nested class names.** A nested class (`class A; class B`) is found by its plain name from anywhere, as
  `GETCONST` does. mruby finds `B` only inside `A` (and `A::B` needs `GETMCNST`, which is refused), so a program that
  names `B` at the top level is an error in mruby and a value here. `inspect` of a nested class prints `A::B`, as mruby.
- **Collector limits.** Strings, arrays, hashes, instances and argument vectors are collected (mark and sweep, see mrbrt.c).
  Classes are never collected (the class table is a root), and neither are symbols (their names are static).
- **Strings are bytes.** This build of mruby has no UTF-8 character handling: `size`, `length` and `[]` count bytes
  (`"é".size` is 2), and `inspect` escapes the bytes of a non-ASCII character as `\xHH`. The runtime does the same.
- **Collection forms.** Iterator results without an explicit block (Enumerators), custom block `to_proc` conversion,
  Hash iteration, optional `find` defaults and `join` separators are not lowered. `Integer#<<` raises
  `NotImplementedError`; the lowered `<<` builtin covers Array and String receivers. String append checks its argument
  directly rather than invoking `to_str`, as mruby does.
- **Recursion.** An array that contains itself inspects as `[...]`, as mruby does. Comparing two such arrays with `==`
  is not guarded and can overflow the C stack.

## Tests

- Reader (`tests/mrbbc/reader/run.sh`): 6 corpus programs and one generated program with registers past 255 (EXT1),
  each compiled four ways (default, `-g`, `--remove-lv`, `-g --remove-lv`): 28 files read by `mrbbc_dump` (every
  instruction decodes, no bytes after END) and run to status 0 by the pinned mruby. 15 malformed files (truncations,
  an extra byte, a wrong magic, format 03.00, an unknown section, an opcode out of range) are refused with status 1.
- Lowering (`tests/mrbbc/lower/run.sh`): 153 value programs match mruby's `p` (two generated: 200 locals, and an
  array literal of 130 elements, which mrbc builds with `ARYPUSH`; the `meth_*.rb` ones cover methods: zero and two
  arguments, self calls between methods, recursion, redefinition, a loop, `return`, and a `def` value; the `blk_*.rb`
  ones cover blocks: yield with and without arguments, a block that sets an outer local, `block_given?`, a loop of
  yields, a block inside a block, a block that calls a method, and `return` out of a block through one or two
  methods); the round 4 ones cover classes (`cls_*.rb`: `new` with and without `initialize`, instance variables, two
  classes with one method name, reopening, a self call from a method, objects passed as arguments, a nested class, a
  loop of method calls, identity, and a class as a value) and break (`blk_break*.rb`, `sendb_*.rb`: from a yield, to the
  innermost call, nested blocks, from a `while` loop in the yielding method, a `SENDB` on an object, and from a
  `SSENDB` in a method), and `blk_splat*.rb` (two and three parameters). Round 5 adds `sup_*.rb` (superclass chains,
  zsuper with and without parameters, `initialize` through `super`, `super` with a block, a reopened class with its
  superclass, a nested `super`), `op_*.rb` and `ins_*.rb` (an operator, `==`, `!=`, `<` and the other comparisons, `+` by
  SEND, the operators and `to_s` of an inherited method, the `to_s` and `inspect` of an instance in a string, an array and
  the printed value). Round 6 adds `sup_blk*.rb` (a super in a block, nested, with a yield and with the implicit block, which
  is nil), and `aref*.rb` (the destructuring of an array, a value that is not an array, nil, and more targets than
  elements). Round 7 adds `opt_*.rb` (optional parameters of methods and blocks: defaults that use earlier parameters, a nil
  and a false default, a method with only optional parameters, recursion, `new` and an operator with an optional parameter,
  and yields to a block with optional parameters, with splats and with more arguments than parameters) and `sup_z*.rb` (a
  zsuper in a block: the arguments, their live values, the block, no parameters, a block parameter, and a zsuper with
  optional parameters). 50 runtime errors match mruby's last stderr line and status 1 (9 from round 1, 13 from round 2, 4
  in round 3: method arity, call before def, and yield without a block; 5 in round 4: an instance's method arity, an
  undefined method of a class, `new` with an argument and no `initialize`, an undefined constant, and a method called
  before its `def` runs; 8 in round 5: six for superclasses (no superclass method, arity of an inherited method, a superclass
  that is not a class, a superclass mismatch, `initialize` with an argument through `super`) and two for operators (an
  undefined operator of an instance, and an operator's arity), and 2 in round 6 (a super in a block with no superclass
  method, and with an arity error), and 4 in round 7 (an optional parameter's arity error, too few and too many, `new` with
  too many arguments for an optional `initialize`, and a zsuper in a block with no superclass method), and 5 more in round
  7 (`super` and `super(1)` at the top level, a zsuper at the top level, a `super` in a top-level block, a `super` in a class
  body, each a NoMethodError); 29 programs are refused with status 3, a `refused:` message and no stdout: 28 in `err/`
  (rest, post, block and keyword parameters, a zsuper in a block of a block of a block, a zsuper in a block with a splat and
  with a keyword argument, and an operator the program defines at the top level). `err/` is the refusal set, `rterr/` the runtime errors; the brief's "err/ programs must be
  refused" is read as the first.

- Measurement (`tests/mrbbc/lower/measure.sh`): one row per value program with the IR bytes, the `.text` bytes of the
  program's object, the peak RSS and the runtime's malloc bytes (total and peak, `runtime/count_alloc.c`, linked with
  `--wrap`). `LOWER_FLAGS` and `RT_FLAGS` select a variant. The `gc_*.rb` programs allocate in loops (string building,
  array churn, objects, blocks) and `int_big.rb` crosses the small-integer ranges of the word layouts.

Round 2 (strings, arrays, SEND0 and SEND of the core methods) is in the tables above. Round 3 lowers methods (see
"Methods": `def` of a method with required parameters, self calls to the program's methods) and blocks (see "Blocks":
`BLOCK`, `SSENDB`, `BLKPUSH`, `BLKCALL`, `GETUPVAR` and `SETUPVAR` at level 0, `block_given?`, and `RETURN_BLK` out of a
block whose home is a method). Round 4 lowers classes (see "Classes") and `BREAK` (see "Blocks"), `SENDB` with an
explicit receiver of a program-defined method, and blocks with two or more parameters. Round 5 lowers superclasses and
`SUPER` (see "Classes" and "Super"), the operators, `to_s` and `inspect` that a program defines in a class (see
"Operators, to_s and inspect"). Round 7 lowers optional parameters of methods and blocks (see "Methods" and "Blocks") and
the zsuper of a block that a method makes, the variables and the implicit block of a block that a block makes (depth 2),
and `SUPER` outside a method (a NoMethodError at run time; see "Super" and "Blocks"). Round 8 lowers rest, post and keyword
parameters of methods and blocks (see "Parameters"), keyword arguments of calls (`SEND`, `SSEND`, `SENDB`, `SSENDB`, `SUPER`,
`new`), splats of arguments (`f(*a)`, `super(*a)`, `[*a]`, `ARYCAT`, `ARYSPLAT`), and `HASH`. Round 9 lowers `**`
parameters and `&nil` of methods, and the `**h` splat of calls (`HASHCAT`, `HASHADD`; see "Parameters"). Still refused: `RETURN_BLK` from a
block of the top level, yields and variables more than two levels out (a block in a block in a block), `SENDB` of a builtin
method, `ASET`, `APOST`, the quoted symbols, a zsuper in a block of depth 3, a block nested more than 8 deep, `yield` in a block
of depth 2 or more (`BLKPUSH` of a block that is not the method's own), the block parameter `&b` (a closure would outlive
its frame if the block were returned or stored; the lowering has no escape analysis; `err/blk_param.rb`, `blk_param_escape.rb`), `**` and `&nil` parameters of a block (`err/blk_kwrest.rb`), the
instance variables of the top level, and a core class as a superclass
(a run-time NotImplementedError: `class E < StandardError`). The strings and arrays in the
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
- `AREF` (the destructuring of `a, b = x`) is lowered as vm.c gives it (`mrbbc_aref`: an array's element, else the value
  at 0 and nil). `ASET` is refused; `GETIDX`, `GETIDX0` and `SETIDX` are the indexing opcodes of mruby 4.0 (the brief's
  OP_GETIDX/OP_SETIDX).
