# swiftfe

A Swift frontend that does not depend on LLVM. It parses Swift with `swift-syntax`
(pure Swift, pinned to 601.0.1), resolves names and checks types in its own
typed IR, and prints C11 that the system `cc` compiles.

```
swift build -c release
.build/release/swiftfe check [--stats] <file.swift | dir>...   # parse only (M0)
.build/release/swiftfe emit-c <file.swift>                     # print C (M1)
.build/release/swiftfe build <file.swift> -o <exe>             # compile with cc (M1)
tests/run.sh                                                   # end-to-end tests (M1 to M3)
```

Diagnostics are printed as `file:line:col: error: message`. Exit status is 0 on
success, 1 on compile errors or check failures, and 2 on usage errors.

## M2: classes, ARC, Optional, enums and closures

Adds to M1:
- classes with stored properties, memberwise construction, and reference semantics
- reference counting in C (`sw_retain`/`sw_release`) with `deinit`, run when the
  last reference goes away. Object fields are released when the object is destroyed.
- Optional types `T?` for Int, Bool, structs and classes: `nil`, implicit wrapping,
  `x!` (traps on nil), `if let`, and `== nil` / `!= nil`
- enums with associated values (`case rect(Int, Int)`), constructed as `Shape.rect(3, 4)`
  or `.rect(3, 4)` when the type is known, and matched with `switch` (exhaustive
  unless there is a `default`)
- function types `(Int) -> Int`, named functions as values, and non-capturing closures
  (`{ $0 * 3 }`, `{ (n: Int) -> Int in n + 1 }`). A closure needs a known function type
  from its context: a declared type, a parameter type, or an assignment target.

Ownership model (documented in `Lower.swift`):
- Owned locals and parameters are released at the end of their block or function,
  and before any `return` that leaves them. Parameters are owned by the callee.
- Locals are released in reverse declaration order.
- Top-level variables are never released, so their `deinit` does not run before exit.
- Assignment retains the new value before releasing the old one.

Closures do not capture: an outer local used inside a closure is reported as not in scope.

Not yet supported in M2 (each gives a diagnostic):
- member access, `!`, or `== nil` on a temporary class value, e.g. `make().x`
- structs with class-typed properties, and enums with class-typed payloads
- labeled enum payloads, raw values, `while let`, class inheritance and methods
- switching over a value other than an enum, and multiple patterns in one case

Verified with AddressSanitizer and LeakSanitizer on the ARC cases: no leaks and no
undefined behaviour. The enum and closure cases are also clean under AddressSanitizer
and UBSan.

## M3: generics

Adds to M2. Generics are compiled by monomorphization: each distinct list of type
arguments is lowered once, with the type parameters bound to those arguments, and
emitted like any other declaration. An instance is named as Swift would write it
(`Box<Int>`), and its C name escapes the punctuation (`s_Box_L_Int_G_`,
`f_first_L_Int_G_`).

Supported:
- generic functions, `func first<T>(_ a: T, _ b: T) -> T`. Type arguments are inferred
  from the argument types (parameter types `T`, `T?`, `(...) -> T` and `Box<T>` are
  matched), from the expected result type, or written out: `first<Int>(1, 2)`.
  A generic function can also be used as a value: `let f: (Bool, Bool) -> Bool = first`.
- generic structs and classes: `Box<Int>`, `Box<T>` in signatures, `Box(value: 1)` with
  the type inferred from the stored properties, and nesting such as `Box<Box<Int>>`.
  Classes keep the ARC rules of M2, so a generic class can hold class references.
- generic enums with payloads: `Maybe<Int>.some(3)`, `Maybe.some(4)` (inferred from the
  payload) and `.some(true)` where the type is declared.
- an operation on a type parameter is checked after substitution, for the type it was
  instantiated with: `a + b` compiles for `Int` and is rejected for `Bool`.

Limits:
- Only instances are checked. A generic body is checked when it is instantiated, not
  when it is declared, so an unused generic is not checked at all. Swift would reject
  `a + b` for an unconstrained `T` in the declaration itself.
- No constraints, protocols or `where` clauses. `T: Equatable` and `where T == Int` give
  a diagnostic.
- No generic methods, initializers, extensions or value generics. A generic struct or
  class has stored properties only, with a memberwise initializer.
- A struct with a class-typed property is still rejected, so `Box<Obj>` (a struct) is
  an error, while `Holder<Obj>` (a class) works.
- Explicit type arguments must be complete (`first<Int>`, not a partial list), and
  `Void` cannot be a type argument.
- Closure and implicit-member arguments are typed after the other arguments. A type
  parameter that appears only in a closure's result cannot be inferred.
- Nested instantiation is limited to 64 levels, so a generic that keeps instantiating
  itself with a larger type is rejected.
- A value type may not contain itself through an instance (`struct Loop { var w: Wrap<Loop> }`).

Verified with AddressSanitizer, UBSan and LeakSanitizer (`cc -fsanitize=address,undefined,leak`
on `swiftfe emit-c` output) on the generic class case, which holds class references.

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
