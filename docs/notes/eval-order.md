# C++17 order of evaluation

C++17 fixes the order in which these operands are evaluated:

| expression | order |
| --- | --- |
| `a.f(b)`, `a->f(b)`, `a.*pm(b)` | `a` before `b` (pm calls: object, then the pointer, then the arguments) |
| `fp(b)`, `f(a)(b)` | the function expression before the arguments |
| `a << b`, `a >> b`, `a[b]` | `a` before `b` |
| `a = b`, `a op= b` | `b` before `a` |
| `new T(args)` | the allocation function call (with placement arguments) before `args` |
| `a , b`, `a && b`, `a \|\| b`, `c ? x : y` | left to right (already so in C) |

The overloaded forms follow the same rules ([over.match.oper]): `os << f() << x` reads `x` after `f()` ran, whether
`operator<<` is a member (`std::ostream`) or a free function. The order of the arguments among themselves
(`g(a(), b())`) stays unspecified.

## The bug

The generated C leaves all of this unspecified, so gcc and cproc/QBE choose their own order. EDG knows the rules
(`strict_cpp17_eval_order`, set by `--c++17` and later, and the `eval_left_to_right` / `eval_right_to_left` flags on
IL operations) and its IL lowering sequences some of it by moving call arguments into temporaries,
`(t1 = a(), t2 = b(), call(t1, t2))`. It did not cover these, so the C compiler ordered them:

- **Member call, object vs. arguments.** `os << f() << x` is `operator<<(operator<<(os, f()), x)`. `lower_call` only
  made temporaries when two or more arguments could change, and never for the `this` expression, so with a single
  argument `x` the inner call (the object expression) and the read of `x` were unsequenced in C. The same for
  `obj().m(x, f())`: when arguments went to temporaries the object was evaluated after them.
- **Function pointer call.** `getfn()(a())`: the function expression against the arguments.
- **Built-in `=` and `op=`.** `*gi() = rv()`, `a[i++] = i`, `x += f()` stay C assignments, and C does not order the
  two sides (gcc happened to run the left side first, cproc/QBE the right side first for `+=`).
- **Built-in `<<`, `>>`, `[]`** with a side effect in the left operand and a right operand that reads state.

## Where it is fixed

In EDG's IL lowering (`3rd/edg/src/lower_il.c`), for every back end: the gcc and QBE paths and Path B all see the
same lowered IL, which is why Path B (`be/nfcxx_ir.c`) needed no change of its own: its IR lowering already evaluates
what it is given left to right (and `op=` right before left, `docs/notes/pathb-stage2.md`), the lost order was in the
IL it was given (the arguments were already temporaries, the object was not).

The submodule stays clean. `scripts/edg-patches/0001-cpp17-eval-order.patch` is applied to a private overlay of the
source (`build/edg-src`, symlinks into `3rd/edg` plus a copy of `lower_il.c`) by `scripts/setup-edg.sh`, and to the
Path B harness tree by `scripts/setup-pathb.sh`; both go through `scripts/edg-patch.sh`. `NFCXX_EDG_PATCHES=0` skips
the patches (an unpatched build to compare against). Rebuild after pulling: `scripts/setup-edg.sh`,
`scripts/setup-pathb.sh`. `setup-edg.sh` also takes `EDG_SRC`, `EDG_BUILD` and `EDG_BASE` to build somewhere else.

The patch adds, only when `strict_cpp17_eval_order` is on:

1. `lower_call`: when some argument is not invariant, the object (`this`) expression and the function / pointer to
   member expression are assigned to temporaries first (object, then function, then the arguments), using the same
   insert location mechanism that already sequences the arguments. Expressions that are invariant (constants, address
   of a variable, a temporary) are left alone, so ordinary calls produce the same C as before.
2. `sequence_operands_of_operation`, called after the operands of a built-in two-operand operation are lowered:
   for `=` the right operand goes to a temporary when it and the left operand's address computation can interact;
   for `op=` when the right operand has a side effect; for `<<`, `>>`, `[]` the left operand when it has a side
   effect and the right operand is not invariant. The operation becomes `(t = operand, operation)`.

Class assignment, `new`, `op=` on `bool` and complex types, and lvalue `?:`/`,` rewrites already had their own
sequencing (`lower_init.c`, `rewrite_compound_assignment`) and are untouched.

## Tests

- `tests/cases/eval_order_calls.cpp`: member and free `operator<<` / `>>` chains (also `std::ostringstream`), object
  expression before arguments (non-virtual, virtual, through a pointer and a reference), function pointer calls.
- `tests/cases/eval_order_assign.cpp`: built-in and overloaded `=`, `op=`, `<<`, `>>`, `[]`, `,`.
- `tests/pathb-qbe/cases/eval_order.cpp`: the same without library headers, compared with the gcc backend by the
  Path B runner (it also runs `tests/cases` on Path B).

Each probe records the order of side effects in a string and compares it. Without the patch probes of both
files fail on the gcc backend, on QBE and on Path B (the member-call ones).

## Not covered

Operands that are unspecified in C++17 too (`a() + b()`, arguments among themselves) keep EDG's choice. Braced
initializer lists (`T{a(), b()}`) are left to right in C++ and were already sequenced by `lower_arg_expr_list`.
Bit-field assignment (`eok_bassign`) is not touched.
