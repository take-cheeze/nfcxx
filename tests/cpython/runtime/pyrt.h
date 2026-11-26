/* The value and the helpers of the CPython 3.13 Path B runtime (tools/cpython/cpy_lower.cpp lowers to these).
 * A PV is 32 bytes: a tag, then the payload words a, b, c. The tags are PV_* below; UNBOUND is 0, so zeroed memory is
 * an unbound name. An INT holds a 64-bit integer in a; a BOOL holds 0 or 1 in a; an ITER (a range iterator) holds the next
 * value in a, the stop in b and the step in c. */
#ifndef NFCXX_CPYTHON_PYRT_H
#define NFCXX_CPYTHON_PYRT_H

#include <stdint.h>

typedef struct PV {
  int64_t tag;
  int64_t a;
  int64_t b;
  int64_t c;
} PV;

enum { PV_UNBOUND = 0, PV_INT = 1, PV_BOOL = 2, PV_NONE = 3, PV_FUNC = 4, PV_ITER = 5 };

/* The module's code, lowered: pyf_0 runs the module, and pyf_K is the function defined K-th at module level. */
void pyf_0(PV *ret, PV *args);

/* Helpers the IR calls. Each one that raises a Python exception prints "Kind: message" on stderr and exits with 1. */
void pyrt_binop(long op, PV *dst, PV *a, PV *b);  /* 0 +, 1 -, 2 *, 3 //, 4 % */
void pyrt_cmp(long op, PV *dst, PV *a, PV *b);    /* 0 <, 1 <=, 2 ==, 3 !=, 4 >, 5 >= */
void pyrt_unop(long op, PV *dst, PV *a);          /* 0 unary -, 1 not, 2 bool() */
int pyrt_truth(PV *a);
void pyrt_check_name(PV *g, const char *name);
void pyrt_check_local(PV *l, const char *name);
void pyrt_init_frame(PV *loc, long n);
void pyrt_range(PV *dst, long argc, PV *args);
int pyrt_for_iter(PV *it, PV *dst);

#endif /* NFCXX_CPYTHON_PYRT_H */
