/* The values of the Squirrel 3.2 subset the lowered IR (tools/squirrelbc/sq_lower.cpp) computes on, and the helpers the IR
 * calls for the slow paths. The layout is the IR's: 16 bytes, the tag (a Squirrel object type word, sqobject.h) at offset 0
 * and the payload at offset 8. An integer or a boolean is its value; a string, table or closure is a pointer to its object
 * (sqbcrt.c). Objects are never freed: the runtime is a test harness, not a collector. */
#ifndef NFCXX_SQBCRT_H
#define NFCXX_SQBCRT_H

#include <stddef.h>
#include <stdint.h>

typedef struct SQV {
  uint32_t tag;
  uint32_t pad;
  int64_t i; /* integer, boolean (0 or 1), 0 for null, or the pointer of a string, table, closure or native closure */
} SQV;

/* sqobject.h's object type words (squirrel.h: OT_NULL, OT_INTEGER, OT_BOOL, OT_STRING, OT_TABLE, OT_CLOSURE,
 * OT_NATIVECLOSURE). */
#define SQBC_TAG_NULL 0x01000001u
#define SQBC_TAG_INTEGER 0x05000002u
#define SQBC_TAG_BOOL 0x01000008u
#define SQBC_TAG_STRING 0x08000010u
#define SQBC_TAG_TABLE 0x0A000020u
#define SQBC_TAG_CLOSURE 0x08000100u
#define SQBC_TAG_NATIVE 0x08000200u

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

/* The dispatcher the IR defines: runs prototype FN (the index of the module's prototypes, main first) on the frame. */
void sq_dispatch(int fn, SQV *ret, SQV *frame);

/* Sets up the stack of NSLOTS values at BASE and the root table, which is the `this` of the main function (base[0]). */
void sqbc_rt_init(SQV *base, size_t nslots);

/* The helpers the IR calls. A runtime error prints `error: MESSAGE` on stdout and exits with status 1. */
void sqbc_rt_arith(int op, SQV *dst, SQV *a, SQV *b);
void sqbc_rt_neg(SQV *dst, SQV *a);
int sqbc_rt_compare(int op, SQV *a, SQV *b);
void sqbc_rt_loadstr(SQV *dst, const char *s, int64_t len);
void sqbc_rt_newtable(SQV *dst);
void sqbc_rt_closure(SQV *dst, int fn, int nparams, int stacksize, const SQV *env);
void sqbc_rt_get(SQV *dst, const SQV *self, const SQV *key, int root_fallback);
void sqbc_rt_set(const SQV *self, const SQV *key, const SQV *val, int root_fallback);
void sqbc_rt_newslot(const SQV *self, const SQV *key, const SQV *val);
void sqbc_rt_call(const SQV *callee, SQV *ret, SQV *frame, int nargs);

/* The text of a string value (NUL-terminated, the bytes of the Squirrel string). */
const char *sqbc_rt_text(const SQV *v);

#endif /* NFCXX_SQBCRT_H */
