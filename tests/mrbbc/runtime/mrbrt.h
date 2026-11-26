/* mrbrt: the runtime of the mruby bytecode producer (tools/mrbbc). A value is 16 bytes: a tag byte at offset 0 and an
 * int64 at offset 8. The tags are the producer's own (they are not mruby's), so a register is an MV in a stack slot.
 *
 * Immediates are nil, false, true and integers. The heap values are a string (tag STR: the int64 is the MStr pointer),
 * an array (ARY: the MAry pointer) and a symbol (SYM: the pointer to its NUL-terminated name, a static string of the
 * module, so two symbols of one name are equal when their pointers are; the EQ helper compares names anyway).
 * Heap objects are malloc'd and never freed: the runtime has no collector (docs/notes/mrbbc-pathb.md).
 *
 * The helpers do what the VM does for the cases the producer does not inline: integer, string, array and symbol
 * operators with mruby's rules, indexing, the methods of SEND0, and the error exits. Strings are byte strings (this
 * build of mruby has no UTF-8 character handling, so size and [] count bytes). Integer overflow is not promoted to a
 * Bignum: it traps (the IR's checked add, sub and mul abort), see docs/notes/mrbbc-pathb.md. */
#ifndef MRBBC_MRBRT_H
#define MRBBC_MRBRT_H

#include <stdint.h>

enum mrbbc_tag {
  MRBBC_NIL = 0,
  MRBBC_FALSE = 1,
  MRBBC_TRUE = 2,
  MRBBC_INT = 3,
  MRBBC_STR = 4,
  MRBBC_ARY = 5,
  MRBBC_SYM = 6,
  MRBBC_BLK = 7,
  MRBBC_OBJ = 8, /* an instance of a class the program defines (the int64 is its MObj) */
  MRBBC_CLS = 9  /* a class the program defines, or Object (the int64 is its MClass) */
};

typedef struct MV {
  uint8_t tag;
  int64_t i;
} MV;

/* The program's methods (TDEF). mrbbc_def adds a top-level method (on Object) with the lowered body's number and the
 * arity; mrbbc_def_in adds one to the class cls (the self of a class body). mrbbc_find returns the number of the body a
 * self call of self runs, or raises ArgumentError (wrong count) or NoMethodError (no such method). mrbbc_find_send is an
 * explicit receiver's call: it returns -1 when the method is not the receiver's class's (the builtin path then runs), and
 * raises NoMethodError for a top-level method, which is private. mrbbc_find_init is the initialize of a new object (-1
 * when there is none and no argument was given). */
void mrbbc_def(const char *name, int id, long arity);
void mrbbc_def_in(const MV *cls, const char *name, int id, long arity);
int mrbbc_find(const MV *self, const char *name, long argc);
int mrbbc_find_send(const MV *recv, const char *name, long argc);
int mrbbc_find_init(const MV *obj, long argc);
/* SUPER: the method of the superclass of the class method number `method` is defined in, called on self (the name is
 * the one the TDEF gave). It returns -1 for the builtin initialize, which mrbbc_super_nil answers with nil. */
int mrbbc_find_super(const MV *self, int method, const char *name, long argc);
void mrbbc_super_nil(MV *dst);

/* A call of the program's method number id from the runtime (the operators, to_s and inspect of an instance of a program
 * class). The lowered module defines it: one branch per method, as a self call has. */
void mrbbc_user_call(int id, MV *ret, MV *argv, MV *blk);

/* Classes (CLASS, EXEC's class body, TCLASS, GETCONST) and objects. mrbbc_class defines the class name (a nil superclass
 * only) under cbase when it is a class, else under target when that is a class, else Object; an existing class of the
 * name is reopened. mrbbc_object_class is Object (TCLASS at the top level). mrbbc_getconst reads a class by its name, or
 * raises NameError. mrbbc_alloc makes an instance of cls (new). mrbbc_getiv and mrbbc_setiv read and write an instance
 * variable of self (an object or a class; nil for another value). */
void mrbbc_class(MV *dst, const MV *cbase, const MV *super, const char *name, const MV *target);
/* A superclass must be a class (TypeError otherwise), and a reopened class must have the superclass it was made with. */
void mrbbc_object_class(MV *dst);
void mrbbc_getconst(MV *dst, const char *name);
void mrbbc_alloc(MV *dst, const MV *cls);
void mrbbc_getiv(MV *dst, const MV *self, const char *name);
void mrbbc_setiv(const MV *self, const char *name, const MV *v);

/* NoMethodError for a name the receiver does not have (the builtin path of a call the program also defines). */
void mrbbc_no_method(const MV *recv, const char *name) __attribute__((noreturn));

/* Block parameters: mrbbc_splats is true when a yield gave one array (argc 1, argv[1] an array), which a block with two
 * or more parameters splats; mrbbc_ary_elt writes element i of the array, or nil past its end. */
int mrbbc_splats(const MV *argv, long argc);
void mrbbc_ary_elt(MV *dst, const MV *ary, long i);
/* OP_AREF (`a, b = x`): an array's element i, or for a value that is not an array, the value at 0 and nil otherwise. */
void mrbbc_aref(MV *dst, const MV *v, long i);

/* Blocks. mrbbc_block makes the closure of a BLOCK at dst: it stores the block's number, a copy of self, the frame the
 * block was made in and its home (the frame of the method a return leaves), in clo (a 40-byte slot of the caller's
 * frame, the layout of Clo in mrbrt.c). The helpers read a block value: its number, its frame, its home, and argv[0] =
 * its self; mrbbc_blk_load copies the method's block (a nil one raises "unexpected yield"); mrbbc_blk_given writes true
 * or false for block_given?. A return out of a block is pending (mrbbc_return_block) until its home takes it. */
void mrbbc_block(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home);
long mrbbc_blk_id(const MV *blk);
MV *mrbbc_blk_frame(const MV *blk);
MV *mrbbc_blk_home(const MV *blk);
void mrbbc_blk_args(MV *argv, const MV *blk);
void mrbbc_blk_load(MV *dst, const MV *blk);
void mrbbc_blk_given(MV *dst, const MV *blk);
void mrbbc_return_block(const MV *value, MV *home);
void mrbbc_break(const MV *value, MV *home);
int mrbbc_unwinding(void);
void mrbbc_unwind_take(MV *ret, MV *frame);
int mrbbc_break_take(MV *dst, MV *frame);

/* The operators the binop helper takes (the opcode names of mruby's ops.h; NEQ is the SEND of "!="). */
enum mrbbc_op {
  MRBBC_OP_ADD,
  MRBBC_OP_SUB,
  MRBBC_OP_MUL,
  MRBBC_OP_DIV,
  MRBBC_OP_LT,
  MRBBC_OP_LE,
  MRBBC_OP_GT,
  MRBBC_OP_GE,
  MRBBC_OP_EQ,
  MRBBC_OP_NEQ
};

/* The methods of SEND0 that the producer lowers (the codes of mrb_lower.cpp). */
enum mrbbc_method { MRBBC_M_TO_S, MRBBC_M_SIZE, MRBBC_M_LENGTH, MRBBC_M_NOT, MRBBC_M_INSPECT };

/* dst = a OP b. Anything the runtime does not implement for these operands is an error, never a wrong value. Never
 * returns on an error. dst may alias a or b. */
void mrbbc_binop(int op, MV *dst, const MV *a, const MV *b);

/* dst = a new string of the n bytes at p (a copy). */
void mrbbc_str_new(MV *dst, const char *p, long n);

/* dst = the symbol with the name p (static storage; the pointer is the symbol's identity). */
void mrbbc_sym(MV *dst, const char *name);

/* dst = a new empty array with room for cap elements. */
void mrbbc_ary_new(MV *dst, long cap);

/* ary.push(v). ary is an array register. */
void mrbbc_ary_push(MV *ary, const MV *v);

/* dst = recv[idx] (GETIDX). dst may alias recv. */
void mrbbc_getidx(MV *dst, const MV *recv, const MV *idx);

/* dst = recv[0] (GETIDX0). dst may alias recv. */
void mrbbc_getidx0(MV *dst, const MV *recv);

/* recv[idx] = v (SETIDX; the producer copies v into the result register afterwards). */
void mrbbc_setidx(const MV *recv, const MV *idx, const MV *v);

/* dst = str_cat(dst, to_s(src)) (STRCAT): dst must be a string. dst may alias src. */
void mrbbc_strcat(MV *dst, const MV *src);

/* dst = recv.m() for the methods of enum mrbbc_method (SEND0). dst may alias recv. */
void mrbbc_send0(MV *dst, const MV *recv, int m);

/* Writes a boolean to dst (the producer uses it for the result of a comparison). */
void mrbbc_set_bool(MV *dst, int truth);

/* Prints a value the way mruby's p prints it (inspect), then a newline. */
void mrbbc_print(const MV *v);

/* Prints "NAME: MESSAGE (CLASS)" on stderr and exits with status 1, the way the mruby executable reports an uncaught
 * exception (the program name stands where mruby prints file:line; the test compares what follows the last colon). */
void mrbbc_raise(const char *cls, const char *message) __attribute__((noreturn));

/* The program name for the messages (set by the driver). */
extern const char *mrbbc_progname;

#endif /* MRBBC_MRBRT_H */
