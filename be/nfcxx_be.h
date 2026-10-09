/*
nfcxx_be.h -- Path B stage 1: the IL-dump back end (see nfcxx_be.c).

The EDG front end calls back_end() (declared in cfe.c, defined in nfcxx_be.c) once the
file-scope IL is complete and lowered (DO_IL_LOWERING=1). The dump goes to stdout as
s-expressions, one construct per line; expressions are printed inline.

  (translation-unit "hello.cpp")
  (global "name" TYPE)                       file-scope variable (initializers not shown yet)
  (function "_Z3addii"                       defined routines only; names are the linkage (mangled) names
    (returns int)
    (params (param "a" int) (param "b" int))
    (static)                                 storage class, when static
    (block
      (local "x" int)                        non-static locals of the function scope
      (decl "x" int)                         declaration point
      (init "x" constant 1)                  dynamic init: kind, then the value/expression/ctor
      (expr (assign int (var int "x") (const int 1)))
      (if COND THEN [ELSE])  (while COND BODY)  (do-while BODY (until COND))
      (for (init..) (cond E) (step E) BODY)  (switch E BODY)  (case C)  (default)
      (goto "L") (label "L") (return [E]) (empty)
      (block ...)))

Types: int, unsigned_int, ... (spaces become underscores), void, (ptr T), (array N T),
(fn RET (P...)), (struct "N"), (class "N"), (union "N"), (const T), (volatile T).

Expressions: (OP TYPE OPERANDS...). OP is the EDG operator name without its eok_ prefix
(add, call, dot_field, points_to_field, assign, question, cast, subscript, ...).
Leaves: (const TYPE V), (var TYPE "x"), (routine TYPE "f"), (field "m"),
(address BASE OFFSET) for address constants, (string "...") for literals.

Anything not covered prints (unsupported <kind>) (or (unsupported-op N), (unsupported-const K),
(unsupported-type N)) so the dump stays total and can be checked for gaps.
*/

#ifndef NFCXX_BE_H
#define NFCXX_BE_H

/* Called by the front end (cfe.c); defined in nfcxx_be.c. */
void back_end(void);

#endif /* NFCXX_BE_H */
