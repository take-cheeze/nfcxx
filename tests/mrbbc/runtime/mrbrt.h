/* mrbrt: the runtime of the mruby bytecode producer (tools/mrbbc). A value is 16 bytes: a tag byte at offset 0 and an
 * int64 at offset 8. The tags are the producer's own (they are not mruby's), so a register is an MV in a stack slot.
 * The helpers do what the VM does for the cases the producer does not inline: integer arithmetic and comparison with
 * mruby's rules (floor division, ZeroDivisionError, NoMethodError for nil, true and false), and the error exits.
 * Integer overflow is not promoted to a Bignum: it traps (the IR's checked add, sub and mul abort), see
 * docs/notes/mrbbc-pathb.md. */
#ifndef MRBBC_MRBRT_H
#define MRBBC_MRBRT_H

#include <stdint.h>

enum mrbbc_tag { MRBBC_NIL = 0, MRBBC_FALSE = 1, MRBBC_TRUE = 2, MRBBC_INT = 3 };

typedef struct MV {
  uint8_t tag;
  int64_t i;
} MV;

/* The operators the helpers take (the opcode names of mruby's ops.h). */
enum mrbbc_op { MRBBC_OP_ADD, MRBBC_OP_SUB, MRBBC_OP_MUL, MRBBC_OP_DIV, MRBBC_OP_LT, MRBBC_OP_LE, MRBBC_OP_GT,
                MRBBC_OP_GE, MRBBC_OP_EQ };

/* dst = a OP b. ADD SUB MUL DIV on two integers; anything else is an error (NoMethodError) except EQ, which is identity
 * on nil, true, false and integers. Comparisons store true or false. Never returns on an error. */
void mrbbc_binop(int op, MV *dst, const MV *a, const MV *b);

/* Writes a value of the tag to dst (the producer uses it for the result of a truth test). */
void mrbbc_set_bool(MV *dst, int truth);

/* Prints a value the way mruby's p prints it: nil, true, false or the integer in decimal. */
void mrbbc_print(const MV *v);

/* Prints "NAME: MESSAGE (CLASS)" on stderr and exits with status 1, the way the mruby executable reports an uncaught
 * exception (the program name stands where mruby prints file:line; the test compares what follows the first colon). */
void mrbbc_raise(const char *cls, const char *message) __attribute__((noreturn));

/* The program name for the messages (set by the driver). */
extern const char *mrbbc_progname;

#endif /* MRBBC_MRBRT_H */
