# Undefined behavior sanitizer (`-fsanitize=undefined`) and `[[likely]]` / `[[unlikely]]`

`nfcxx -fsanitize=undefined x.cpp -o x` builds a program whose undefined-behavior checks say where they failed.
It selects Path B (EDG lowered IL -> typed IR -> QBE), because the checks are IR operations: the gcc and qbe-via-C
backends compile C, where signed overflow and the other cases are not checked.

```
$ nfcxx -fsanitize=undefined x.cpp -o x && ./x
before
x.cpp:5: runtime error: signed integer overflow
Aborted                                   # SIGABRT, status 134, like the silent checks
```

## What is checked

Path B's IR already had checked operations. They were silent (`abort()`), and only signed overflow was optional. The
sanitizer turns signed overflow on and gives every check a report:

| check (`-fsanitize=`) | IR operation | report |
| --- | --- | --- |
| `signed-integer-overflow` | `cadd csub cmul cneg`, `cdiv`/`crem` for `INT_MIN / -1` | signed integer overflow (`...: division of the minimum value by -1`) |
| `integer-divide-by-zero` | `cdiv crem` | division by zero |
| `shift` | `cshl cshr` | shift exponent is negative or not less than the width of the type |
| `bounds` | `bounds` (array subscripts of known length, VLAs too) | index out of bounds for the array |
| `null` | `nonnull` (dereference, call through a null function pointer, virtual call) | null pointer dereference or call through a null pointer |
| `unreachable` | `unreachable` (`__builtin_unreachable`) | execution reached an unreachable program point |
| `return` | `(unreachable missing-return)` | execution reached the end of a value-returning function without returning a value |
| `float-cast-overflow` | `cf2i` | value is outside the range of representable values of the target integer type |
| `undefined` | all of the above | |

Limits, stated so that they are not mistaken for coverage:

- **Only `signed-integer-overflow` (and `undefined`) changes what is checked.** The other checks above are always on in
  Path B (a zero divisor, an out-of-range shift and so on are never silently executed), so `-fsanitize=bounds` alone still
  traps on a zero divisor; the flag only turns the reports on. `-fno-sanitize=all` turns the reports off; other
  `-fno-sanitize=` forms and `-fsanitize-*` options are refused.
- Not implemented (refused with a message): `alignment`, `vptr`, `bool`, `enum`, `pointer-overflow`, `object-size`,
  `nonnull-attribute`, `returns-nonnull-attribute`, `vla-bound`, `unsigned-integer-overflow`, `address`, `thread`, `leak`.
  Subscripts through a plain pointer are not bounds-checked (`pathb-stage2.md`, "Decisions").
- The report has no operand values and no column: the place is the file and line of the **statement** being executed
  (a `for` loop's condition and step report the `for` line). A statement that spans lines reports its first line.
- The program stops at the first failure (no `-fsanitize-recover`): the IR has no code after a failed check.
- Instantiated templates and inline functions from headers report the header's file and line.

## How it works

1. `nfcxx` exports `NFCXX_IR_SANITIZE=<list>`; `be/nfcxx_ir.c` reads it. Signed `+ - *` and unary `-` become the checked
   forms (the same as `NFCXX_IR_OVERFLOW=trap`).
2. The lowering prints `(loc "FILE" LINE)` before a statement whenever the position changed, and re-prints it before the
   step of a loop. A function left without a value ends in `(unreachable missing-return)` instead of `(unreachable)`.
   Without the variable none of this is printed, so the IR (and the goldens in `tests/pathb-ir`) are unchanged.
3. `scripts/pathb-qbe-emit.rb` (and its Python oracle) remember the last `(loc ...)`. A check that fails jumps to a block
   of its own for that (kind, file, line): `call $__nfcxx_ubsan_report(kind, file, line)`; `hlt`. Without a `(loc ...)` all
   checks of a function share the one `abort()` block, as before. The file name is a data item of the object.
4. `__nfcxx_ubsan_report` is in `be/nfcxx_ldrt.c`, i.e. in `libnfcxxld.a`, which every Path B link already adds. It prints
   `file:line: runtime error: message` to stderr (after flushing stdout) and calls `abort()`. `__nfcxx_smul64_ovf`, in the
   same file, is the 64-bit signed multiply check: QBE has no wide product, so the emitter asks the library
   (`__builtin_mul_overflow`). Before, a checked 64-bit `cmul` was refused, which also made programs with a variable-length
   array fail in trap mode.

## `[[likely]]` and `[[unlikely]]`

EDG records the attributes on statements and does nothing with them; the lowering used to drop them. Now:

- On an `if`, the arm statement's attribute becomes a `(likely)` or `(unlikely)` statement at the start of that arm of the IR
  (`pathb-stage2.md`, section 5). EDG wraps an arm in a block and puts the attribute on the first statement inside, so that
  statement speaks for the arm: `if (c) { [[likely]] f(); }` hints the same way as `if (c) [[likely]] f();`, which is how the
  standard treats a path that contains the statement. Both hints on one `if` that disagree (`[[likely]]` then, `[[likely]]`
  else) cancel and the layout is unchanged.
- The QBE emitter lays the likely arm out right after the test and the unlikely one out of line. QBE has no branch weights, but
  it orders blocks by depth-first search and puts the *second* successor of a `jnz` next (`3rd/qbe/cfg.c`, `porec`), so the
  emitter makes the likely arm the second successor, inverting the test when it has to. The effect is checked in the
  assembly: `tests/pathb-qbe/cases/likely_unlikely.cpp` (`// ASM-ORDER: FUNCTION FIRST SECOND`).
- The checks use the same mechanism: a failed check is the first successor of its branch (`trap_if`), and `trap_unless` is
  inverted to that form, so the sanitizer's reports are out of line in every function, with or without `-fsanitize`. Before,
  `trap_unless` (bounds, null, shift, float cast, 32-bit overflow) put the abort block right behind the test.
- The WebAssembly and PTX emitters ignore the three new statements (`loc`, `likely`, `unlikely`); they have no use for them.
- Not done: hints on `switch` case labels, on loops, and `__builtin_expect` (still ignored, `__builtin_expect(c, 0)` as an
  `if` condition does not mark the arm).

## Tests

- `tests/pathb-qbe/traps/ubsan_*.cpp`: one program per check; each must abort and its stderr must contain
  `FILE:LINE: runtime error: ...` (`// TRAP-SANITIZE: undefined`, `// TRAP-STDERR: ...`).
- `tests/pathb-qbe/cases/ubsan_clean.cpp` (`// SANITIZE: undefined`): a program with no undefined behavior, at the edges of
  every range, runs the same with the checks and agrees with the gcc backend.
- `tests/pathb-qbe/cases/likely_unlikely.cpp`: results are independent of the hints, and the likely call comes first in the
  assembly of each function.
- `tests/mruby/run.sh` compares the Ruby emitter with its Python oracle on the IR goldens; both implement the new statements.
