/* The runtime of the QuickJS Path B producer (tools/quickjs/qjs_lower.cpp): the values and the operators the lowered IR
 * calls. A JV is the 16-byte value of the IR's (struct "JV"): a tag and a payload. The operators of the first subset work on
 * int32 numbers, booleans, null and undefined. A result that JavaScript would give as a non-int32 number (a fraction, a
 * NaN, an infinity, -0, an overflow) is not represented: the program stops with a message and status 1 (qjrt_fail).
 * The operator codes are the ones of qjs_lower.cpp (enum Op, enum UnOp). */
#ifndef QJRT_H
#define QJRT_H

#include <stdint.h>

typedef struct {
  int64_t tag;
  int64_t val;
} JV;

enum { QJRT_UNDEF = 0, QJRT_INT = 1, QJRT_BOOL = 2, QJRT_NULL = 3, QJRT_UNINIT = 4 };

enum {
  QJRT_ADD, QJRT_SUB, QJRT_MUL, QJRT_DIV, QJRT_MOD, QJRT_LT, QJRT_LE, QJRT_GT, QJRT_GE, QJRT_EQ, QJRT_NE, QJRT_SEQ,
  QJRT_SNE
};
enum { QJRT_NEG, QJRT_PLUS, QJRT_LNOT };

void qjrt_binop(int op, JV *dst, const JV *a, const JV *b);
void qjrt_unop(int op, JV *dst, const JV *a);
void qjrt_inc(int delta, JV *dst, const JV *a);
void qjrt_post(int delta, JV *old, JV *neu, const JV *a);
int qjrt_truthy(const JV *a);
void qjrt_check_init(const JV *a, const char *name);
void qjrt_check_global(const JV *a, const char *name);

#endif /* QJRT_H */
