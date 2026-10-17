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
  unless there is a `default`). A payload may be a class, Optional class or another such
  enum (`case full(Node)`). Such an enum is reference-counted like a class value: copies
  retain, owned locals and `switch` subjects release, and a payload bound by `case .full(let n)`
  is retained for the arm.
- function types `(Int) -> Int`, named functions as values, and closures
  (`{ $0 * 3 }`, `{ (n: Int) -> Int in n + 1 }`, and closures that capture; see
  "Closure captures" below). A closure needs a known function type from its context: a
  declared type, a parameter type, or an assignment target.

Ownership model (documented in `Lower.swift`):
- Owned locals and parameters are released at the end of their block or function,
  and before any `return` that leaves them. Parameters are owned by the callee.
- Locals are released in reverse declaration order.
- Top-level variables are never released, so their `deinit` does not run before exit.
- Assignment retains the new value before releasing the old one.
- A function value is reference-counted through its context, so it is owned like a
  class reference. A struct with a function-valued property is reference-counted too,
  and so is an enum or array element that holds one.

Not yet supported in M2 (each gives a diagnostic):
- member access, `!`, or `== nil` on a temporary class value, e.g. `make().x`
- structs with class-typed or array properties, or with enum properties that hold a class
  (a struct may hold function values)
- Optional enums that hold a class are supported only as `E?` values; their `if let` works,
  but temporary values of them cannot be bound or compared with `nil` (as for classes)
- an implicit member such as `.full(n)` cannot be written where the context is `E?`
  (write `E.full(n)`)
- `_` as a payload pattern, e.g. `case .pair(_, let n)`
- labeled enum payloads, raw values, class inheritance
- switching over a value other than an enum, and multiple patterns in one case
- `while let` over a temporary class value, e.g. `while let n = next(of: m)` where
  `next` returns a class (the binding would have to take the temporary's reference)

`while let x = opt { ... }` is supported for any Optional expression that is not a
temporary class value: locals, parameters, fields, and calls returning `Int?` or the
like. The optional is read again on each iteration, and the binding follows the same
release rules as `if let`.

Top-level variables are C statics, so they stay reachable until exit. Their objects
are never freed, and LeakSanitizer does not report them.

The sanitizer pass in `tests/run.sh` checks every runnable case with AddressSanitizer,
LeakSanitizer and UBSan.

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
- same-type requirements in a `where` clause on a generic function, struct, class or enum:
  `where T == Int`, `where T == Double`, `where T == Bool`. The requirement is checked for
  each instance: `same(true, false)` is rejected for `where T == Int`, and the body is
  lowered with `T` bound to the type the clause fixes.

Limits:
- Only instances are checked. A generic body is checked when it is instantiated, not
  when it is declared, so an unused generic is not checked at all. Swift would reject
  `a + b` for an unconstrained `T` in the declaration itself.
- Constraints and protocols are not supported. `T: Equatable`, `where T: Equatable` and any
  other conformance or layout requirement give the diagnostic `generic parameter constraints
  are not supported yet`.
- A `where` clause is accepted only on a generic function, struct, class or enum. One on a
  method, an initializer or a declaration without type parameters is refused.
- A same-type requirement is not used to infer a type parameter. `func zero<T>() -> T where
  T == Int` needs `zero<Int>()`, or an expected type, or an argument that fixes `T`.
  Requirements with value generics (`where T == 3`) are refused, and so is a requirement
  with no bare type parameter on either side (`where Int == Bool`, `where [T] == [Int]`).
- No extensions or value generics. Generic types may have initializers and methods. A generic struct or
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
- trailing closures, implicit member access, `switch`, `guard`

Type checking follows Swift's rules for this subset. Missing returns and recursive
structs are rejected. The checks produce Swift's messages where they match the
Swift compiler, but the wording is not guaranteed to be identical.

## Control flow, Double and arrays

Supported:
- `break` and `continue` in loops. Each releases the owned locals it leaves.
- `break` inside a `switch` leaves the switch, and `continue` inside a switch continues
  the enclosing loop. The switch is an if-chain, so the break jumps to a label after it
  (emitted only when a break uses it). The subject is still released once, after the label.
- `for i in a..<b` and `for i in a...b` over Int; `for x in array`, which loops over a copy.
- `for x in xs where cond` over Int ranges and arrays. The body runs only for the elements
  where `cond` holds, in order; `continue` and `break` work as in a plain loop.
- `guard let`, `guard cond`, with bindings that stay in scope after the guard.
- `switch` over Int and Bool with literal, range (`4...9`) and several-value cases.
  Int needs a default; Bool must cover both values. Enum cases may list several
  patterns when they bind nothing.
- `switch` over Double with literal, several-value and range (`0.0..<1.0`, `1.0...2.5`)
  cases. Integer and negated literals are Doubles there (`case 1:`, `case -2.0:`). The
  first matching case runs. A default is required.
- `Double` with literals, `+ - * /`, comparisons, `Double(n)` and Swift's printing.
- Arrays `[T]` of any element type: Int, Bool, Double, structs, classes, enums that hold
  classes, optionals and nested arrays. Literals, `a[i]` (reads and writes, trapping out of
  range), `a.count`, `a.append(x)`, `for x in a`, and `print` of arrays of Int, Bool or
  Double. Arrays are values: copying one copies the buffer, and each class element in it
  gets its own reference (retained, then released when the buffer is freed, in order).
- Structs and enum payloads that hold arrays, including a struct that holds an array of
  itself (`struct Tree { var kids: [Tree] }`). Such a struct is class-like: a copy copies
  its arrays, and its owner frees them. A struct may not hold a class, directly or through
  another struct, an enum or an Optional (structs with class-typed properties are still
  rejected). Class fields may hold arrays already.
- Optional arrays (`[Int]?`): assignment, `x!`, `if let`, `== nil`, and `x![i]`.
- Subscripts and `count` of a temporary array, e.g. `make()[0]` and `make().count`. The
  temporary is freed after the element is read, and a class element is returned owned.

Limits (each gives a diagnostic):
- arrays of classes, enums or function values, arrays in struct properties, enum payloads or optionals
- subscripts and `count` of a temporary array
- `switch` over String; `%` on Double (Swift rejects it too, see "Operators" below)

## Initializers, overloads and temporaries

Supported:
- `return` inside an initializer. A bare `return` releases the owned locals it leaves
  (its parameters and the locals of the enclosing blocks) and returns `self`. The
  initializer's implicit return is skipped when the body already ends in a `return`.
- Overloaded functions, methods and initializers: the same name with different argument
  labels or types. The labels choose the candidates, then the argument types choose one.
  An exact type match beats one that needs Optional wrapping, so `f(1)` picks `f(_: Int)`
  over `f(_: Int?)`. A closure, `nil`, an array literal, an implicit enum case or a function
  name takes its type from the candidate. A function name used as a value picks its
  overload from the expected function type. Overloads with the same labels and types are
  redeclarations. Each overload has its own C name (`f_show`, `f_show_1`, ...).
- a method called on a temporary class value, e.g. `Make().describe()`, in any statement,
  condition or loop. The method borrows the receiver, so a wrapper `cs_<method>` releases it
  once the method returns, as Swift does: the deinit output comes before the rest of the
  enclosing expression. The method's result is owned, so it does not depend on the receiver.

Limits (each gives a diagnostic):
- `return` with a value in an initializer
- overloads of a generic function, or a generic function with a plain overload of the same
  name. Arguments of an overloaded call are typed before the candidate is chosen, so a generic
  call that needs its parameter's type to infer its type arguments is not supported there.
- an ambiguous call, such as `f(nil)` with `f(_: Int?)` and `f(_: Bool?)`

## Integration tests

`tests/integration/run.sh` builds each testbed program in `tests/integration/programs`
and compares its output with the output of the real Swift compiler. The expected
files were generated by `tests/integration/oracle.sh`, which runs `swiftc` from the
toolchain on PATH. The emitted C of every program must also be clean under
AddressSanitizer, LeakSanitizer and UBSan.

The programs are the testbed for the next steps: they use only what the subset
supports, plus a few features that are still missing (see the file headers). The
current programs are: binary trees, Collatz, primes, Hanoi, an accumulator machine
on an enum, a traffic-light state machine, closures, an optional linked list with
`deinit`, and a generic stack.

Supported in this step beyond M2 and M3:
- explicit `init` for classes and structs (non-generic and generic), with the
  initializer chosen by argument labels; the memberwise initializer is available only
  when no explicit one exists
- methods on classes and structs, called as `obj.method(args)` or, inside a type, as
  `method(args)`; a method's receiver is borrowed, and a temporary class value is released
  once the method returns (see "Initializers, overloads and temporaries")
- implicit `self` for properties, in initializers, deinitializers and methods
- `if let a = x, let b = y, cond { ... }`: each condition is tested in order
- top-level variables are visible to functions and closures
- `_` as a payload pattern in `switch`

Limits of this step (each gives a diagnostic):
- a failable initializer

## Closure captures

A closure can read and assign the locals of the functions around it. The closure value
is still a function value of its declared type, so it can be returned, stored and
passed like a closure that captures nothing. A function value is a pair `{ fn, ctx }`:
a named function or a non-capturing closure has a NULL context, and a capturing closure
has a heap context that holds its captured values.

Supported:
- a captured `let` or parameter is copied into the context when the closure is made. A
  class-like copy is retained, so the context owns it
- a captured `var` lives in a box, a heap cell owned by the scope that declares it. The
  closure and the scope share the box, so an assignment in either is seen in the other.
  Every `var` whose name appears inside some closure of the file is boxed, which can
  box more variables than needed but gives the same results
- closures in closures capture transitively, and a closure can be returned from a
  function that declared the captured local
- a method's closure captures `self`
- captured values of any class-like type: classes, arrays, structs with function values,
  enums and Optionals of these
- a struct, enum or class may hold a function value, including a capturing one, and an
  array may hold structs that hold function values
- top-level variables are globals, not captures, so a closure reads and assigns them directly

Limits (each gives a diagnostic):
- a closure needs a contextual function type, as before: `let f = { ... }` is rejected
- the type of a generic parameter cannot be inferred from a closure argument alone
- arrays of function values and Optionals of function values
- a `break` or `continue` cannot leave a closure, since a closure has its own loops only

Verified against the Swift compiler's output and with the sanitizers on the emitted C.

## Operators

Supported, by operand type:
- `Int`: `+ - * / %` (overflow, division by zero and remainder by zero trap, as before),
  the wrapping operators `&+ &- &*` (two's complement, no trap), the bitwise operators
  `& | ^` and unary `~`, the shifts `<<` and `>>`, comparisons, `==` and `!=`, and unary `-`.
  Shifts follow Swift's smart shifts: a count of 64 or more gives 0 for `<<`, and for `>>`
  gives 0 or -1 by the sign; a negative count shifts the other way, and bits shifted out
  are dropped without a trap. Precedence comes from swift-syntax's standard operator table.
- `Double`: `+ - * /`, comparisons, `==`, `!=`, and unary `-`.
- `Bool`: `&&`, `||`, `!`, `==` and `!=`.

Refused (each gives a diagnostic):
- `%` on `Double`. Swift rejects it too, with `binary operator '%' cannot be applied to two
  'Double' operands`. The alternative `truncatingRemainder` is not offered, since method calls
  on `Double` are not supported.
- `&+ &- &*`, `& | ^`, `<< >>` on `Double` and `Bool`, and `~` on `Double` and `Bool`
- the masking shifts `&<<` and `&>>`, and any other operator not listed above, which
  gives `operator '...' is not supported in M2`

## Tests

`tests/run.sh` builds each case in `tests/cases` and checks it:
- `NAME.expected`: stdout must match exactly
- `NAME.trap`: the program must exit nonzero after the expected output
- `NAME.error`: compilation must fail with this diagnostic line

After the functional cases, every case that is not an `.error` case is also built
from its emitted C with `-fsanitize=address,leak,undefined`. The sanitized binary must
print the same output and exit the same way (0, or nonzero for a trap case).

## M0 status

The parser checks above were run before M1 was added and are repeated after each
change. The truncated-input result shows the parser recovers from broken input
without crashing or losing source text.
