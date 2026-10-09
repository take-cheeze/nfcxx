# Scripting with mruby instead of Python

Goal: the build's own helper scripts run on a small mruby interpreter that the repository builds itself,
so `python3` stops being a host-tool requirement. mruby is C99, MIT licensed, and it already builds with
nfcc (`tests/realworld/run_mruby.sh`), so the interpreter can be built by the compiler it serves.

## Stage 1 (done): infrastructure and the two pilot scripts

| Piece | What it is |
| --- | --- |
| `scripts/setup-mruby.sh` | Clones mruby 4.0.0 (`831da26b`, the pin `tests/realworld/run_mruby.sh` uses) into `build/mruby-tool/src`, builds with rake and installs `build/mruby-tool/bin/mruby`. Host `cc` by default. `MRUBY_CC=<repo>/nfcc` also builds `bin/mruby-nfcc` with nfcc (the host one is always built first, because `scripts/qbe-cc` runs mruby). |
| `scripts/mruby-tool-config.rb` | The build config: core, `mruby-io`, `mruby-pack`, `mruby-sprintf`, `mruby-string-ext`, `mruby-array-ext`, `mruby-hash-ext`, `mruby-set`, `mruby-enum-ext`, `mruby-numeric-ext`, `mruby-kernel-ext`, `mruby-object-ext`, `mruby-symbol-ext`, `mruby-range-ext`, `mruby-error`, `mruby-exit`, `mruby-bigint` (stage 3), `mruby-bin-mruby`; and the define `MRB_ARY_LENGTH_MAX=0`, because mruby caps an `Array` at 131072 entries by default (`array size too big`) and the token list of a big translation unit is longer (stage 3). Reuses the HAL workaround of `tests/realworld/mruby_build_config.rb`: naming the `hal-posix-*` gems stops mruby's `for_windows?` guess (any `/a/../z/` directory means "Windows") from picking the wrong HAL. |
| `scripts/mrb` | `scripts/mrb script.rb args...`; builds the interpreter first when it is missing. `MRB=<exe>` picks another interpreter. |
| `scripts/weak-symbols.rb` | Port of `weak-symbols.py`; used by `scripts/qbe-cc`. |
| `scripts/qbe-prep.rb` | Port of `qbe-prep.py` (stage 3, below); used by `scripts/qbe-cc`. |
| `tests/hexagon/flatlink.rb` | Port of `flatlink.py`; used by `tests/hexagon/run.sh`. |
| `scripts/pathb-qbe-emit.rb` | Port of `pathb-qbe-emit.py` (done, see the section below); used by `tests/pathb-qbe/run.sh`. |
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
`e_startup_*.ir`.

## Bootstrap caveat

Building mruby needs a CRuby with the `rake` gem; mruby is not self-hosting in its build. Checked on the
pinned 4.0.0: `minirake`, which older mruby shipped as a standalone rake replacement, is now a two-line
script, `#!/usr/bin/env ruby` / `exec "rake", *ARGV`, so **minirake alone does not suffice**: it needs
the same `rake` gem plus `ruby`. `setup-mruby.sh` finds `rake` on `PATH`, then in the gem bindir (the
case on this machine, where the gem is installed but not linked into `PATH`), then falls back to
`ruby -rrake`. On Ubuntu 24.04, `apt-get install ruby rake` is enough.

Consequences: `ruby` replaces `python3` in the host-tool list rather than removing the need for a
scripting language at bootstrap. It is only needed once, to build `build/mruby-tool/bin/mruby`; every
later run uses the interpreter. To drop CRuby entirely one would have to vendor a prebuilt `mruby`
binary, or write a small make-based build for the chosen gem set (mruby's core is plain C99 plus
generated files from `mrbc`, which itself needs bootstrapping), which is not planned.

The mruby build also fetches from GitHub (a shallow fetch of the pinned commit). For an offline setup,
mirror `github.com/mruby/mruby` like the submodules in `build-self-hosting.md`.
