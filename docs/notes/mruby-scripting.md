# Scripting with mruby instead of Python

Goal: the build's own helper scripts run on a small mruby interpreter that the repository builds itself,
so `python3` stops being a host-tool requirement. mruby is C99, MIT licensed, and it already builds with
nfcc (`tests/realworld/run_mruby.sh`), so the interpreter can be built by the compiler it serves.

## Stage 1 (done): infrastructure and the two pilot scripts

| Piece | What it is |
| --- | --- |
| `scripts/setup-mruby.sh` | Clones mruby 4.0.0 (`831da26b`, the pin `tests/realworld/run_mruby.sh` uses) into `build/mruby-tool/src`, builds with rake and installs `build/mruby-tool/bin/mruby`. Host `cc` by default. `MRUBY_CC=<repo>/nfcc` also builds `bin/mruby-nfcc` with nfcc (the host one is always built first, because `scripts/qbe-cc` runs mruby). |
| `scripts/mruby-tool-config.rb` | The build config: core, `mruby-io`, `mruby-pack`, `mruby-sprintf`, `mruby-string-ext`, `mruby-array-ext`, `mruby-hash-ext`, `mruby-set`, `mruby-enum-ext`, `mruby-numeric-ext`, `mruby-kernel-ext`, `mruby-object-ext`, `mruby-symbol-ext`, `mruby-range-ext`, `mruby-error`, `mruby-exit`, `mruby-bigint` (added for `pathb-qbe-emit.rb`), `mruby-bin-mruby`. Reuses the HAL workaround of `tests/realworld/mruby_build_config.rb`: naming the `hal-posix-*` gems stops mruby's `for_windows?` guess (any `/a/../z/` directory means "Windows") from picking the wrong HAL. |
| `scripts/mrb` | `scripts/mrb script.rb args...`; builds the interpreter first when it is missing. `MRB=<exe>` picks another interpreter. |
| `scripts/weak-symbols.rb` | Port of `weak-symbols.py`; used by `scripts/qbe-cc`. |
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
  (now in the set, for `pathb-qbe-emit.rb`; without it `1 << 64` raises and such a literal does not parse): write
  `(1 << 32) - 1` instead of `0xffffffff` in scripts that should not depend on it.
- `String#to_f` is not correctly rounded (`"0.10000000149011612".to_f` is one ulp off) and `sprintf("%.17e")` /
  `Float#to_s` print at most about 15 significant digits. Do exact conversions with bigint arithmetic
  (`dec_to_double`, `py_float_repr` in `pathb-qbe-emit.rb`). `Float#nan?` works where `v != v` does not, and
  `-v` loses the sign of a zero (`v * -1.0` does not).
- No `Enumerator` gem: `each_byte`, `each_with_index` and `each_char` need a block (use `bytes`, `each_with_index { }`).
  `Array#sort_by` is not stable: add the index to the key when Python's stable `sorted` matters.
- Operator precedence differs from Python: `a & b == 0` is `a & (b == 0)`; write the parentheses.
- Exit codes: `exit 1` (from `mruby-exit`); messages to `$stderr`.

## Stage plan for the other two scripts

`scripts/qbe-prep.py` (614 lines) was not touched in stage 1, because other work was changing it; port it when that
work has landed. (`pathb-qbe-emit.py` was ported next, see "Stage 3" below; the numbering is historical.)

### Stage 2: `qbe-prep.py` to `qbe-prep.rb`

Python features it uses, and the mruby answer:

| Python | mruby |
| --- | --- |
| `re` tokenizer (`TOKEN_RE`, `finditer`) | hand-written scanner, below |
| `re.fullmatch` on `.align N`, `.globl X`, `A = B` (asm lines) | small split/`index` checks on whitespace-split fields |
| `re.search`/`re.fullmatch` for numeric literals (`UL_CONST`, `FLOAT_LIT`, `ATOMIC_RE`) | check the token text with character loops; `ATOMIC_RE` is `__atomic_` + one of eight operation names + an optional size suffix, so `start_with?` plus a table lookup |
| `fractions.Fraction` in `ieee_bits` (exact decimal-to-IEEE for `_Float16/32/64/128` literals) | `mruby-rational` (core, not in the set) and `mruby-bigint` (core, in the set since `pathb-qbe-emit.rb`) if the arithmetic is kept as written; or integer-only: parse the decimal literal into `digits * 10**exp` and do the rounding with bigint shifts. 113-bit mantissas (`_Float128`) exceed 64 bits, so `mruby-bigint` is required for stage 2 (available now). |
| `class Tok` with `__slots__` | `Struct` (`mruby-struct`) or a plain class |
| f-strings, `sys.exit(msg)` | interpolation, `$stderr.puts` + `exit 1` |
| `os.environ.get('NFCXX_C_INPUT')` | no `ENV` in this gem set (there is no `mruby-env` in mruby 4.0.0 core): `scripts/qbe-cc` passes it as an extra argument (`--c-input`) |

Tokenizer design without Regexp. The Python regex is an ordered alternation tried at each position:
whitespace, `//` comment, `/* */` comment, string (`u8`/`L`/`u`/`U` prefix), char literal, number,
identifier, any single character. Port it as one loop over bytes with `getbyte`, dispatching on the first
byte:

1. whitespace (`" \t\n\r\f\v"`): skip a run.
2. `/` followed by `/` or `*`: find the end with `index("\n", i)` or `index("*/", i + 2)`; an unterminated
   `/*` must fall through to the single-character case, as the regex does when `.*?` finds no end.
3. `"` or `'`, or a prefix (`u8`, `L`, `u`, `U`) immediately followed by one: scan forward, skipping
   `\` plus the next byte, stopping at the closing quote; a raw newline before the end means "not a
   literal" (the regex class excludes `\n`), so the prefix is then an identifier and the quote a punct.
4. digit, or `.` followed by a digit: take `[eEpP][+-]` pairs and word/`.` bytes (the `num` pattern).
5. identifier start (letter, `_`, `$`): take word bytes.
6. anything else: one byte.

Keep `start`/`end` offsets exactly (the rewriter edits the source by offset), and keep UTF-8 bytes >= 0x80
as single-byte puncts or word bytes consistently with Python's `\w` (check what the generated C contains;
EDG output is ASCII except inside string literals, which the scanner skips whole).

### Stage 3 (done, ported first): `pathb-qbe-emit.py` to `pathb-qbe-emit.rb`

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
