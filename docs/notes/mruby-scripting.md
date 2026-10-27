# Scripting with mruby instead of Python

Goal: the build's own helper scripts run on a small mruby interpreter that the repository builds itself,
so `python3` stops being a host-tool requirement. mruby is C99, MIT licensed, and it already builds with
nfcc (`tests/realworld/run_mruby.sh`), so the interpreter can be built by the compiler it serves.

## Stage 1 (done): infrastructure and the two pilot scripts

| Piece | What it is |
| --- | --- |
| `scripts/setup-mruby.sh` | Clones mruby 4.0.0 (`831da26b`, the pin `tests/realworld/run_mruby.sh` uses) into `build/mruby-tool/src`, generates a ninja build file with `scripts/mruby-ninja.rb` (no rake) and builds it with ninja, then installs `build/mruby-tool/bin/mruby`. Host `cc` by default. `MRUBY_CC=<repo>/nfcc` also builds `bin/mruby-nfcc` with nfcc (the host one is always built first, because `scripts/qbe-cc` runs mruby). |
| `scripts/mruby-tool-config.rb` | The build config: core, `mruby-io`, `mruby-pack`, `mruby-sprintf`, `mruby-string-ext`, `mruby-array-ext`, `mruby-hash-ext`, `mruby-set`, `mruby-enum-ext`, `mruby-numeric-ext`, `mruby-kernel-ext`, `mruby-object-ext`, `mruby-symbol-ext`, `mruby-range-ext`, `mruby-error`, `mruby-exit`, `mruby-bigint` (stage 3), `mruby-bin-mruby`; and the define `MRB_ARY_LENGTH_MAX=0`, because mruby caps an `Array` at 131072 entries by default (`array size too big`) and the token list of a big translation unit is longer (stage 3). Reuses the HAL workaround of `tests/realworld/mruby_build_config.rb`: naming the `hal-posix-*` gems stops mruby's `for_windows?` guess (any `/a/../z/` directory means "Windows") from picking the wrong HAL. |
| `scripts/mrb` | `scripts/mrb script.rb args...`; builds the interpreter first when it is missing. `MRB=<exe>` picks another interpreter. |
| `scripts/weak-symbols` | Was `weak-symbols.rb` (the port of `weak-symbols.py`); now the C++ tool `tools/weak-symbols` behind this wrapper, used by `scripts/qbe-cc` and `scripts/gcc-cc`. The mruby script took 292 s on the 48 MB of C that ggml-cuda's binbcast.cu gives (character positions in a large string cost a scan in mruby); the tool takes under 2 s. The oracle stays. |
| `scripts/qbe-prep.rb` | Port of `qbe-prep.py` (stage 3, below); used by `scripts/qbe-cc`. |
| `tests/hexagon/flatlink.rb` | Port of `flatlink.py`; used by `tests/hexagon/run.sh`. |
| `scripts/pathb-qbe-emit.rb` | Port of `pathb-qbe-emit.py` (done, see the section below); used by `tests/pathb-qbe/run.sh`. |
| `scripts/cil-link.rb` | Port of `cil-link.py` (stage 5, below); used by `scripts/qbe-cc` (the CIL backend) and `scripts/pathb-cil`. Takes `--ilasm`, `--cc` and `--keep-il` as arguments. `tests/mruby/cil-link.sh` checks it. |
| `scripts/qbe2cil.rb` | Port of `tests/mruby/oracle/qbe2cil.py` (done, see the stage 4 section below); used by `scripts/qbe-cc` on the CIL backend (so `scripts/cil-cc`). |
| `scripts/pathb-cil-emit.rb` | Port of `pathb-cil-emit.py` (stage 6, below); used by `scripts/pathb-cil`. |
| `tests/mruby/run.sh` | Runs the Python original and the port on real inputs and compares the output byte for byte. The originals are kept as oracles in `tests/mruby/oracle/`; nothing else uses them. CI runs it. |

What the test compares:

- weak-symbols: the QBE assembly of nine `tests/cases` (front end, preprocess, `qbe-prep.py`, cproc, QBE),
  four of which contain `.weak` lines, plus a hand-written file with nested `__attribute__` groups,
  declarations and a label that must not match.
- flatlink: the Hexagon objects of every `tests/cases` that clang compiles, the HVX kernel, an object it
  must refuse (`SKIP-undef`), a non-ELF file and a missing entry symbol; compared are the output image,
  the stderr text and the exit status. Both parts skip when EDG/QBE/hexagon clang are missing.
  The test also passes with the interpreter built by nfcc (gcc back end):
  `NFCXX_BACKEND=gcc MRUBY_CC=$PWD/nfcc scripts/setup-mruby.sh`, then `MRB=build/mruby-tool/bin/mruby-nfcc tests/mruby/run.sh`.
- pathb-qbe-emit: the QBE IL, the stderr text and the exit status of the Python original and the port over every
  `tests/pathb-ir/*.ir`, the 130 hand-written IR files in `tests/mruby/pathb-edge/` (every refusal and error
  message, 64-bit unsigned constants, float constants and `cf2i` bounds, data initializers, switch/loop/goto,
  variadic calls, `setjmp`, latin-1 bytes, CRLF input), and the IR of `tests/pathb-qbe/{cases,multi,traps}` and
  `tests/cases` when the Path B harness is built (`PATHB_CPFE`); each with and without `--no-prune`, plus stdin,
  usage errors and `--append-weak`. It needs only python3 and the interpreter (no EDG or QBE) for the stored IR.
- pathb-cil-emit (`tests/mruby/pathb-cil-emit.sh`): the JSON fragment (the output file; the original writes nothing to
  stdout), stdout, stderr and the exit status of the Python original and the port over every `tests/pathb-ir/*.ir` and
  `borrow/*.ir`, the hand-written IR in `tests/mruby/pathb-cil-edge/` (one file per refusal and error path of the
  emitter, and the success forms of the number atoms, data initializers, the try idiom and an indirect call; `x_*`
  files make the original raise, so only the status is compared), the IR of `tests/pathb-cil/cases` when the Path B
  harness is built, and generated inputs (CRLF, octal escapes in a name, stdin, usage errors, a missing file).
- qbe2cil: the JSON fragment (byte for byte), and the exit status with a message on stderr, of the Python original and the
  port over the QBE IL in `tests/mruby/qbe2cil/`: ten `real_*.ssa` (IL made once by the repo's front end from `tests/cases`,
  `tests/c` and `tests/cil/cases`; the recipe is in `tests/mruby/qbe2cil.sh`), four hand-written `e_*.ssa` (every data
  item form, every operator and compare, aggregates, the export quirk, UTF-8 and DEL bytes in names) and fifteen
  refusals `r_*.ssa`. The assembly tail is an input: both runs must leave it unchanged. Used by `tests/cil/run.sh`
  through `scripts/qbe-cc`.

### Rules for scripts written for this interpreter

- No `Regexp` (mruby core has none, and no regexp gem is in the set). Scan by hand with `String#index`,
  `rindex`, `getbyte`, `byteslice`, or a character-class table.
- Strings are byte strings (no UTF-8 gem): use `getbyte`/`byteslice` for binary data and pack/unpack with
  `File.open(path, "rb") { |f| f.read }`; there is no `File.binread`.
- `Integer` is 64 bit. mruby 4 parses a literal above `2**31 - 1` as a bigint, which needs `mruby-bigint`
  (in the set since stage 3, for the exact float-literal arithmetic of `qbe-prep.rb`): scripts still write
  `(1 << 32) - 1` instead of `0xffffffff`, so they do not depend on it.
- An `Array` holds at most 131072 entries in a stock mruby; the config lifts the cap (`MRB_ARY_LENGTH_MAX=0`).
  An interpreter built from another config (for example the `bin/mruby` of `tests/realworld/run_mruby.sh`)
  fails on `qbe-prep.rb` for large inputs.
- No `ENV`: a script gets its settings as arguments (`qbe-prep.rb --c-input`). No `Time`, no `Enumerator`
  (`each_with_index`, `each_byte` and the like need a block: use `bytes`, `each_with_index { }`), and
  `sort_by` / `sort` are not stable (add an index to the sort key).
- Strings are byte strings. Python's text-mode `open().read()` translates `\r\n` and `\r` to `\n`; a port that
  must be byte-identical has to do that itself (`read_text` in `qbe-prep.rb`).
- `String#to_f` is not correctly rounded (`"0.10000000149011612".to_f` is one ulp off) and `sprintf("%.17e")` /
  `Float#to_s` print at most about 15 significant digits. Do exact conversions with bigint arithmetic
  (`dec_to_double`, `py_float_repr` in `pathb-qbe-emit.rb`). `Float#nan?` works where `v != v` does not, and
  `-v` loses the sign of a zero (`v * -1.0` does not).
- Operator precedence differs from Python: `a & b == 0` is `a & (b == 0)`; write the parentheses.
- Exit codes: `exit 1` (from `mruby-exit`); messages to `$stderr`.
- No `Process` (so no `Process::Status`, no `system`, no backticks that report a status). Run a command with
  `IO.popen("cmd >out 2>err; echo $?")` (`/bin/sh -c`) and read the status from the output.
- `JSON.parse` (mruby-json) reads an integer above `2**63 - 1` as a Float, which loses its bits. Quote such
  numbers before the parse and convert them back after it (`quote_big_ints`, `restore_big_ints` in `cil-link.rb`).

## Stage 3 (done): `qbe-prep.py` to `qbe-prep.rb`

`scripts/qbe-prep.rb` (about 1200 lines with the comments, the Python was 760) replaces `scripts/qbe-prep.py`; `scripts/qbe-cc` runs
`scripts/mrb scripts/qbe-prep.rb [--c-input] PP.c OUT.c TAIL.s`. The Python is the oracle
`tests/mruby/oracle/qbe-prep.py` (it still reads `NFCXX_C_INPUT` from the environment; the port takes
`--c-input`, which `qbe-cc` passes exactly when `NFCXX_C_INPUT` is non-empty, as before).

How the Python features were answered:

| Python | mruby |
| --- | --- |
| `re` tokenizer (`TOKEN_RE`) | `tokenize`: one loop over bytes (`getbyte`), the alternatives of the regex in the same order: whitespace, `//` and `/* */` comments (an unterminated `/*` falls through to a `/` punct, as the regex does), string and char literals with the `u8`/`L`/`u`/`U` prefix (`scan_quoted`: a backslash takes any next byte, a raw newline means "not a literal", so the prefix becomes an identifier and the quote a punct), numbers (`[eEpP][+-]` pairs and word bytes), identifiers (`$` allowed first), any other single byte. Bytes >= 0x80 count as word characters, where Python's `\w` would also match non-ASCII letters; EDG's output and glibc's headers are ASCII outside literals. |
| `re.fullmatch` for `.align N`, `.globl X`, `A = B`, `UL_CONST`, `FLOAT_LIT`, `ATOMIC_RE`, the `L` suffix of 4c | small hand-written matchers (`align_text?`, `globl_name`, `set_names`, `ul_const?`, `float_lit`, `atomic_parts`, `long_double_literal?`) |
| `fractions.Fraction` in `ieee_bits` | integers only (`mruby-bigint`): the decimal literal is `digits * 10**exp`; the exponent is found with `bit_length` and two shift comparisons, the mantissa is `divmod` rounded half to even. No `mruby-rational` needed. |
| `int(text, 0)` (alignment, array bound) | `py_int0`: decimal, `0x`, `0o`, `0b`, underscores; anything else exits 1 (Python raises `ValueError`) |
| `unicode_escape` in `decode_str` | `decode_str`: the C escapes, octal, `\x`, `\u`, `\U` |
| `sorted(edits, reverse=True)` then applying edit by edit | `apply_edits`: sorts on `[-start, -end, index]` (Python's reverse sort is stable), splices all non-overlapping edits in one pass, and replays one at a time only if two edits overlap |
| `class Tok` with `__slots__`, f-strings, `sys.exit(msg)` | plain class, interpolation, `die` (`$stderr.puts` + `exit 1`) |

Verification, `tests/mruby/qbe-prep.sh` (called by `tests/mruby/run.sh`): `tests/mruby/qbe-prep-tap.sh` is put in
place of the interpreter (`MRB=`) while `nfcxx` compiles everything on the QBE back end, and copies each
input `qbe-cc` really hands to `qbe-prep.rb` (and whether it was `--c-input`). Python and the port then run on
every copy; the output C, the assembly tail, stderr and the exit status must be identical. Corpora: all
`tests/cases`, `tests/builtins`, `tests/lib`, `tests/c` (the C inputs with the C-input mode), and from
`build/realworld`, when cached, tinyxml2, doctest (4.6 MB of C) and Lua (33 C files). `QBE_PREP_CORPUS=<dir>`
adds the captures of any other run, for example `tests/realworld/run_mruby.sh` (the rake build of mruby with
nfcc, which exercises the overflow builtins and the setjmp code) with `MRB` set to the tap. Then about 60
hand-written edge cases, each in the plain and the C-input mode, one or more per rewrite: aligned attributes
on arrays and structs, `__bf16` and `_Float16/32/64/128` types and literals (rounding ties, the extreme
normal values, subnormal and overflow refusals), constructors with and without priority, thread_local
aliases (weak and not), every int3 asm form, unsupported top-level asm, the overflow builtins (the constant
multiply shape, same-type helpers, mixed types, argument-count refusals), volatile locals in every declaration
position, `alloca`, the sized atomics, `(double)...L` literals, floatn typedefs, and tokenizer corner cases
(unterminated comment/string, escapes, prefixes, `$`, CRLF, non-ASCII, EOF in the middle of each construct).
The test fails when a corpus yields no input, when fewer than 60 inputs or 8 refusals are compared, or when
a kind of rewrite never occurs in the Python output.

Speed (this machine, interpreter built with the host cc): the scanner is a byte loop in the VM, about 1.4 to
1.6 times slower than the regex-based Python. tinyxml2.cpp (387 KB of generated C): 0.21 s Python, 0.34 s mruby,
and a whole `qbe-cc -c` of it takes 0.55 s; doctest (4.6 MB): 2.8 s Python, 3.9 s mruby. Two things mattered:
single-byte punct tokens share one string each (no allocation), and identifiers that no rewrite looks at are
skipped before the rewrite tests (`SPECIAL_ID`); together they took doctest from 6.0 s to 3.9 s.

Uncaught Python exceptions (a malformed number such as `1.2.3f16` or `__aligned__(16U)`) become an exit 1 with
a different message (a traceback in Python); the test compares only the exit status for those.

## Stage 2 (done): `pathb-qbe-emit.py` to `pathb-qbe-emit.rb`

`scripts/pathb-qbe-emit.rb` is a line-by-line port; `tests/pathb-qbe/run.sh` runs it through `scripts/mrb`. The
Python original is the oracle `tests/mruby/oracle/pathb-qbe-emit.py`. What the port needed:

- `re` (three anchored patterns: `%(\d+)$`, `[A-Za-z_][A-Za-z0-9_.]*$`, the integer atom `-?(0x[0-9a-fA-F]+|\d+)`):
  character loops (`reg?`, `qname?`, `as_int`). The `$` of the originals also matches before a final newline; the
  loops do too.
- `struct.pack("f")`: `[v].pack("e").unpack("e")` (it also raises on overflow, as `struct` does).
- `math.isfinite`: `Float#finite?`.
- `repr(float)` (Python prints the shortest digits that read back the same double; the constants end up in the QBE
  text): rebuilt from exact bigint arithmetic (`shortest_digits`). `float(str)` is `dec_to_double`, exact and
  round-half-even, with Python's grammar (`inf`, `nan`, `1e999` is inf).
- Integer constants up to `2**64 - 1`, `1 << 64` and `-(1 << 63)`: **`mruby-bigint` was added to the gem set**
  (`scripts/mruby-tool-config.rb`; `rational` was not needed). `wrap_int` uses `%` instead of `&` on a bigint.
  Two more mruby bigint defects, both found by the bit-field work and both avoided in the emitter (the py-vs-rb
  comparison caught them): `~x` of a bigint is wrong (`~((1 << 64) - 1)` gave a value that wraps to 2, not 0), so masks
  are built with `^` on positive numbers; and comparing a fixnum with a bigint goes through a double, so
  `9223372036854775807 >= 1 << 63` is true. `wrap_int` tests the sign bit with `v >> (bits - 1) != 0` for that reason.
  Shifts, `%`, `&`, `|` and `^` on non-negative bigints behaved.
- Python tuples in messages (`('int', 4, True, False)`, and the one-element `((...),)` form that
  `"%s" % (x[0], (ty,))` prints): `tyrepr`/`ty1`; `%r` of a name: `py_str_repr`.
- The IR is read as latin-1 with universal newlines and stderr is UTF-8: bytes in, `u8()` on the way to stderr. A
  string token keeps its characters as integer codes (`IRStr#codes`), because an octal escape can exceed 255.
- Dispatch tables hold lambdas; `case`/`default` markers are matched by `object_id` (Python used `id()`).

Known differences, none reachable from the corpus:

- **Python bug not copied.** The original tests `t == "("` on tokens, and a quoted string token is a `str`
  subclass, so a string constant `"("` or `")"` in the IR is read as a parenthesis (error `unbalanced`). The port
  tells the two apart. A C++ program that prints `"("` would have broken Path B before; `tests/mruby/run.sh` checks
  that the port handles it and the original does not.
- Uncaught exceptions (a missing input file, `float("abc")`, a float constant that overflows single precision) end
  with status 1 in both, but the text on stderr is a Python traceback or an mruby backtrace. Malformed forms that
  make Python raise `IndexError`/`TypeError` make the port raise `NoMethodError` or carry a `nil` on.
- The header comment of the IL and the usage text still say `pathb-qbe-emit.py`, so the output stays identical.

### How to verify each port is byte-identical

Same method as stage 1, add to `tests/mruby/run.sh` before deleting anything:

1. Move the `.py` original to `tests/mruby/oracle/` only after the port passes (until then run it from
   `scripts/`).
2. Inputs: every `tests/cases/*.cpp` through the front end (`nfcxx --emit-c`), then the stage's script
   with the Python and the mruby version, `cmp` the output files, compare stderr text and exit status.
   For `qbe-prep`: also `NFCXX_C_INPUT=1` over `tests/c/*.c` and the `tests/realworld` sources
   (tinyxml2, doctest, mruby itself: the largest, ~1 MB of preprocessed C each; check mruby's speed
   on them, a byte loop in the VM is far slower than a compiled regex).
3. Make sure the comparison is not vacuous: assert that the rewrite actually changed something (count the
   `_Float16`, `__atomic_*`, top-level `asm` rewrites) over the whole corpus.
4. Hand-written edge cases for what the generated C does not exercise: unterminated comment, string with
   an escaped quote, `u8""`, `1e+5f16`, `0x1p-3`, a lone `$` identifier.
5. `tests/run.sh` on both backends and `tests/c/run.sh` must still pass with the port in `scripts/qbe-cc`.

If mruby turns out too slow for the tokenizer on large inputs, the fallback is to write that one tool in
C and build it with `scripts/setup-qbe.sh`-style `make`; the byte-identical test stays the same.

### Emitter features added after the port

Behaviour added to `pathb-qbe-emit.rb` is added to the oracle `tests/mruby/oracle/pathb-qbe-emit.py` in the same
change, so the byte-for-byte comparison stays strict: the `(constructor [PRIO])` / `(destructor [PRIO])` function
markers (`.init_array` / `.fini_array` tables, reachability roots) and the pointer cells for the address of a function
defined elsewhere (`pathb_got.NAME`). Edge inputs: `tests/mruby/pathb-edge/startup.ir`, `fnaddr.ir`,
`e_startup_*.ir`. Later additions, in both files in the same change: the `(barrier)` statement (an empty module-local
function `$__pathb_barrier`; `barrier.ir`, `e_barrier_form.ir`), the top-level `(declare "NAME" (weak))`, the weak
undefined object `(global ... (weak) (extern))` (address through the GOT, `.weak`) and `(weak attr)` definitions that
pruning keeps (`weak_decl.ir`, `e_declare_form.ir`, `weakref_tls_init.ir`; the old `_ZTH` name rule is gone), and a
refusal of an `(unsupported ...)` statement that prints the marker (`r_unsupported_asm.ir`).
The address of a thread-local object is always `copy extern thread $x` (initial-exec, valid in a
shared library) also for a definition in the module; the oracle changed with it (covered by `thread_data.ir`,
`r_thread_addr.ir` and the `tests/pathb-ir/tls*.ir` goldens).

## Stage 4 (done): `qbe2cil.py` to `qbe2cil.rb`

`scripts/qbe2cil.rb` replaces `scripts/qbe2cil.py` (the CIL backend's translation of one unit's QBE IL into a JSON
fragment); `scripts/qbe-cc` runs `scripts/mrb scripts/qbe2cil.rb IN.ssa TAIL.s TU OUT.json`. The Python is the oracle
`tests/mruby/oracle/qbe2cil.py`. How the Python features were answered:

- The regexes (the instruction and definition heads, `CMP_INT`/`CMP_FLT`, `z N`, the data operands `$sym + N`, the type
  declarations with their lazy name, `.quad` lines of the tail): one hand-written scanner each (`assignment_parts`,
  `cmp_int`, `data_token`, `type_def`, `fn_head`, `quad_name`, ...), each with the regex in a comment. The `\s` of the
  originals is ASCII whitespace plus `\x1c`-`\x1f`.
- `json.dump(fragment, indent=1)`: `json_dump` writes the same layout (one space per level, `[]` and `{}` when empty) and
  `json_string` the default `ensure_ascii` escapes (`\u007f` for DEL, surrogate pairs above U+FFFF, invalid UTF-8 as
  U+FFFD per Python's `replace` rule). Keys stay in the order the original inserts them (`variadic` comes last, after
  `ctors`), and `addrs` is the sorted list of the set.
- Float constants: `float()` and `float.fromhex()` are exact (`dec_to_double`, `hex_to_double`, both through
  `ratio_to_double`); `struct.pack('<f')` is `to_single`, which raises where Python does (a finite value rounding to
  infinity). `d_nan` is the positive quiet NaN (`nan_bits`), as Python's `float('nan')` is.
- `int(text, 0)` is `py_int0` with the sign; the two's complement of a constant is `% (1 << bits)` and the sign bit test
  `>> (bits - 1)`, as in `wrap_int`.
- The file is read with universal newlines (`read_text`), split with the empty last piece kept (`split_lines`, not
  `String#split`, which drops it). Errors are `die` (`qbe2cil: ...`, status 1), as `sys.exit` is.

Known differences, none reachable from cproc's IL: Python's `\s` also matches non-ASCII spaces; a non-ASCII byte inside
a string literal of a data item is one byte (Python reads one code point, which is an error or a Latin-1 value);
`float()` accepts underscores (`1_0`), the port does not; the tail's `.quad` regex is applied line by line, so a
`.quad` whose name is on the next line is not found. Uncaught Python exceptions give a traceback, the port a
`qbe2cil:` line; both exit 1, and the test compares only the status for those.

## Stage 5 (done): `cil-link.py` to `cil-link.rb`

`scripts/cil-link.rb` replaces `scripts/cil-link.py`, which moved to `tests/mruby/oracle/cil-link.py`. The callers
(`scripts/qbe-cc` for the CIL backend, `scripts/pathb-cil`) pass what the Python read from the environment: `--ilasm`
(the `ILASM` setting, default `build/cil/ilasm`), `--cc` (`CC`, for the variadic call shim) and `--keep-il`
(`NFCXX_KEEP_IL`). The fragments are read with `JSON.parse`; the integers above `2**63 - 1` (a float64 whose sign bit
is set is one) are quoted first, see the rules above. ilasm and the shim's C compile run through `IO.popen`, with
stdout and stderr in files next to the output, and the status is read back from the shell.

`tests/mruby/cil-link.sh` (called by `tests/mruby/run.sh`) links the same fragments with the oracle and the port: the
fragments of `tests/cil/cases/*.c` (nfcc with `NFCXX_BACKEND=cil -c`, the qbe2cil route) and of
`tests/pathb-cil/cases/*.cpp` (`pathb-dump --ir` and `pathb-cil-emit.py`). For each: the CIL text, the failed IL and the
runtime config byte for byte, the exit status, and the output of the linked program (its status, its stdout, the
`EXPECT` line and the `.out` file). Hand-written fragments in `tests/mruby/cil-link/`: `bigint.json` (the integer
bit patterns), `bad-il.json` (ilasm refuses it: `OUT.failed.il`), `bad-main.json` (a main with arguments). Usage errors
compare the exit status, and the message where the two versions print the same text. The DLL itself is not compared
(ilasm writes a new module id each time); the programs are. Parts 1 and 2 need the front ends and are skipped without
them. Not reproduced: the Python traceback of an uncaught error (a missing fragment, `-o` without its name), where
only the status is compared, and the ilasm error text, which names the temporary IL file.

## Stage 6 (done): `pathb-cil-emit.py` to `pathb-cil-emit.rb`

`scripts/pathb-cil-emit.rb` replaces `scripts/pathb-cil-emit.py`; `scripts/pathb-cil` runs
`scripts/mrb scripts/pathb-cil-emit.rb IR.txt OUT.json`. The Python is the oracle `tests/mruby/oracle/pathb-cil-emit.py`.
The fragment is written to the output file (`json.dump`, `indent=1`), so stdout stays empty in both.

| Python | mruby |
| --- | --- |
| `re` in `tokenize` (`\d`, the hex and float atoms) | `atom_value` and `tokenize` scan the code points by hand; `isdigit_py` keeps Python's `str.isdigit`, which is also true for the superscripts, and `int()` then refuses them |
| `json.dump(indent=1)` | `json_val`: the same layout (`[]` and `{}` when empty) and the `ensure_ascii` escapes (`é`, `\u007f`), so no JSON gem is needed |
| `latin-1` text, one character per byte; an octal escape can reach 511 | the input is read as bytes and every string is a UTF-8 string of code points (`cps` / `from_cps`), so `len()` and the escapes are per code point |
| text-mode `open()` (universal newlines) | `main` translates `\r\n` and `\r` for a file; stdin is not translated, as in the original |
| `int(v)`, `float(v)`, `struct.pack` | `py_int`, `py_float_of`, `pack_double` / `pack_single`: exact (`float_to_int`, `dec_to_double`); `pack('e')` gives infinity where `struct` raises, so `pack_single` raises the overflow itself |
| `x[i]` (IndexError, TypeError) and `bool(x)` | `pyidx` and `truthy`: mruby's `nil` and `Integer#[]` would not raise |
| `str(x)` / `repr(x)` in messages | `pys` / `py_repr` (a list prints as `[...]`, a `Ref` as `glob"x"`, `None` as `None`) |

Known differences, none reachable from the corpus: a `Tmp` (a Python object without a repr) inside a message prints
without its address, and the traceback of an uncaught exception is an `error:` line. Both exit with status 1, as the
original does, and the `x_*` inputs of the test compare only the status for them. The original's bug with a quoted
`"("` in the IR (the token reads as a parenthesis) is kept, not fixed: the port must give the oracle's output.

## Bootstrap caveat

Building mruby needs a CRuby (stdlib only) and ninja; the rake gem is not needed. `setup-mruby.sh` runs
`scripts/mruby-ninja.rb generate`, which evaluates the build config (`scripts/mruby-tool-config.rb`) and each gem's
`mrbgem.rake` against a small stub of the rake DSL, then writes `build.ninja`; ninja builds it. The generator
refuses any mrbgem.rake call it does not model, so a gem it cannot handle fails the setup rather than building
wrongly. A gem's `file` tasks run as ninja edges: a task that builds a file in a build directory runs its block
through the same mrbgem.rake (`gemtask`), as rake would; a task on a source file only adds its prerequisites to the
compile unit (its block is not run, and the generator says so). `rule` and `directory` are refused.
`tests/mruby-ninja/run.sh` checks a generated header and the refusal. mruby's own rake build (`tests/realworld/run_mruby.sh`) still needs rake: it is the upstream build that
the generator is checked against. On Ubuntu 24.04, `apt-get install ruby ninja-build` is enough.

Consequences: `ruby` replaces `python3` in the host-tool list rather than removing the need for a
scripting language at bootstrap. It is only needed once, to build `build/mruby-tool/bin/mruby`; every
later run uses the interpreter. To drop CRuby entirely one would have to vendor a prebuilt `mruby`
binary, or write a small make-based build for the chosen gem set (mruby's core is plain C99 plus
generated files from `mrbc`, which itself needs bootstrapping), which is not planned.

The mruby build also fetches from GitHub (a shallow fetch of the pinned commit). For an offline setup,
mirror `github.com/mruby/mruby` like the submodules in `build-self-hosting.md`.

### Host tools of the vendored gems

The gems under `3rd/` (`mruby-json`, `mruby-onig-regexp`) need the submodules initialized
(`git submodule update --init 3rd/mruby-json 3rd/mruby-onig-regexp`). `mruby-onig-regexp` bundles Onigmo 6.2.0
and builds it itself unless a system Onigmo or Oniguruma header is found. That build runs `sh` (its `configure`
ships in the tarball, so autotools are not needed), `make`, `ar` (also used to archive the objects), `gzip` and
`tar` (to unpack the tarball), and the C compiler (`cc`, or the `MRUBY_CC` given). `setup-mruby.sh` checks for
`cc`, `make`, `ar`, `gzip` and `tar` before the build starts and names each missing one with its package
(`apt-get install binutils` for `ar`, `build-essential` for the compiler). `sh` is not checked: every POSIX host has it.
