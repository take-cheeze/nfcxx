/* The values of the Squirrel 3.2 subset the lowered IR (tools/squirrelbc/sq_lower.cpp) computes on, and the helpers the IR
 * calls for the slow paths. The layout is the IR's: 16 bytes, the tag (a Squirrel object type word, sqobject.h) at offset 0
 * and the payload at offset 8. */
#ifndef NFCXX_SQBCRT_H
#define NFCXX_SQBCRT_H

#include <stdint.h>

typedef struct SQV {
  uint32_t tag;
  uint32_t pad;
  int64_t i; /* integer, boolean (0 or 1), or 0 for null */
} SQV;

/* sqobject.h's object type words (OT_NULL, OT_INTEGER, OT_BOOL). */
#define SQBC_TAG_NULL 0x01000001u
#define SQBC_TAG_INTEGER 0x05000002u
#define SQBC_TAG_BOOL 0x01000008u

/* Helper operands: the Squirrel opcode numbers of the operator (sqopcodes.h), and CmpOP (CMP_G, CMP_GE, CMP_L, CMP_LE). */
#define SQBC_OP_ADD 0x11
#define SQBC_OP_SUB 0x12
#define SQBC_OP_MUL 0x13
#define SQBC_OP_DIV 0x14
#define SQBC_OP_MOD 0x15
#define SQBC_CMP_G 0
#define SQBC_CMP_GE 2
#define SQBC_CMP_L 3
#define SQBC_CMP_LE 4

/* The lowered program's entry point (sq_fn_0 of the main prototype). */
void sq_fn_0(SQV *ret, SQV *base);

/* The helpers the IR calls. A runtime error prints `error: MESSAGE` on stdout and exits with status 1. */
void sqbc_rt_arith(int op, SQV *dst, SQV *a, SQV *b);
void sqbc_rt_neg(SQV *dst, SQV *a);
int sqbc_rt_compare(int op, SQV *a, SQV *b);

#endif /* NFCXX_SQBCRT_H */
