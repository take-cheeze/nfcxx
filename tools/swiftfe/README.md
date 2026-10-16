# swiftfe

A Swift frontend that does not depend on LLVM. It parses Swift with `swift-syntax`
(pure Swift, pinned to 601.0.1), resolves names and checks types in its own
typed IR, and prints C11 that the system `cc` compiles.

```
swift build -c release
.build/release/swiftfe check [--stats] <file.swift | dir>...   # parse only (M0)
.build/release/swiftfe emit-c <file.swift>                     # print C (M1)
.build/release/swiftfe build <file.swift> -o <exe>             # compile with cc (M1)
tests/run.sh                                                   # end-to-end tests (M1 and M2)
```

Diagnostics are printed as `file:line:col: error: message`. Exit status is 0 on
success, 1 on compile errors or check failures, and 2 on usage errors.

## M2: classes, ARC and Optional

Adds to M1:
- classes with stored properties, memberwise construction, and reference semantics
- reference counting in C (`sw_retain`/`sw_release`) with `deinit`, run when the
  last reference goes away. Object fields are released when the object is destroyed.
- Optional types `T?` for Int, Bool, structs and classes: `nil`, implicit wrapping,
  `x!` (traps on nil), `if let`, and `== nil` / `!= nil`

Ownership model (documented in `Lower.swift`):
- Owned locals and parameters are released at the end of their block or function,
  and before any `return` that leaves them. Parameters are owned by the callee.
- Locals are released in reverse declaration order.
- Top-level variables are never released, so their `deinit` does not run before exit.
- Assignment retains the new value before releasing the old one.

Not yet supported in M2 (each gives a diagnostic):
- member access, `!`, or `== nil` on a temporary class value, e.g. `make().x`
- structs with class-typed properties
- enums with associated values, closures, `while let`, class inheritance and methods

Verified with AddressSanitizer and LeakSanitizer on the ARC cases: no leaks and no
undefined behaviour.

## M0: parsing

`check` parses each file, prints syntax errors, and checks that the lossless tree
prints back to the exact input bytes. `--stats` counts node kinds.

| Input | Files | Result |
| --- | --- | --- |
| `swift-syntax/Sources` | 333 | all clean |
| `swift-syntax/Tests` | 257 | all clean |
| `.swiftinterface` files from the Swift 6.1 toolchain | 92 | all clean |
| Those interfaces truncated at 30%, 50% and 70% | 276 | no crashes, every tree round-trips, 241 of 276 files reported errors |

## M1: a core subset

Supported:
- `Int` (64-bit, checked arithmetic), `Bool`, `Void` functions
- global functions with argument labels, `_` labels, and recursion
- structs with stored `Int`, `Bool` or struct-typed properties, memberwise init, and
  nested field access and assignment
- `let` and `var` with an initializer, optional type annotation, and block scoping
- `if`/`else`, `while`, `return`, assignment to `var` locals and fields
- `+ - * / %`, comparisons, `== !=` on `Int` and `Bool`, `&& || !`, unary `-`
- top-level statements, run in order from `main`
- `print` for `Int` and `Bool`

Runtime behaviour matches Swift: integer overflow and division by zero trap (the
program prints `Fatal error: ...` on stderr and aborts).

Not yet supported (each gives a diagnostic, not a crash):
- generics, protocols, closures, methods, computed properties, initializers,
  default property values, optionals, `String`, arrays, `Double`
- top-level variables used from functions (only top-level code sees them)
- trailing closures, implicit member access, `switch`, `guard`

Type checking follows Swift's rules for this subset. Missing returns and recursive
structs are rejected. The checks produce Swift's messages where they match the
Swift compiler, but the wording is not guaranteed to be identical.

## Tests

`tests/run.sh` builds each case in `tests/cases` and checks it:
- `NAME.expected`: stdout must match exactly
- `NAME.trap`: the program must exit nonzero after the expected output
- `NAME.error`: compilation must fail with this diagnostic line

## M0 status

The parser checks above were run before M1 was added and are repeated after each
change. The truncated-input result shows the parser recovers from broken input
without crashing or losing source text.
