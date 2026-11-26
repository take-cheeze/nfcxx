/* mrbrt: the runtime of the mruby bytecode producer (tools/mrbbc). A value is 16 bytes: a tag byte at offset 0 and an
 * int64 at offset 8. The tags are the producer's own (they are not mruby's), so a register is an MV in a stack slot.
 *
 * Immediates are nil, false, true and integers. The heap values are a string (tag STR: the int64 is the MStr pointer),
 * an array (ARY: the MAry pointer) and a symbol (SYM: the pointer to its NUL-terminated name, a static string of the
 * module, so two symbols of one name are equal when their pointers are; the EQ helper compares names anyway).
 * Heap objects are collected by a mark-and-sweep collector (mrbrt.c, "the collector"): the program runs under mrbbc_run.
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
  MRBBC_CLS = 9, /* a class the program defines, or Object (the int64 is its MClass) */
  MRBBC_HASH = 10 /* a hash: the keyword arguments of a call, and the kdict of a method with keyword parameters */
};

typedef struct MV {
  uint8_t tag;
  int64_t i;
} MV;

/* The program's methods (TDEF). mrbbc_def adds a top-level method (on Object) with the lowered body's number, its counts
 * of arguments, min (the required and post parameters) to max (the ones before the rest parameter and the optional ones;
 * -1 with a rest parameter), and flags (bit 0: it has keyword parameters; bit 1: it has only required parameters, the fast
 * path of vm.c's ENTER); mrbbc_def_in adds one to the class cls (the self of a class body). A call's count argc is its
 * positional arguments; kw is 1 when the call gave keyword arguments, whose hash is the call's last argument (a method
 * without keyword parameters takes it as a positional one, as vm.c does), and 2 for an empty `**h` splat (positional only
 * on the fast path, see mrbbc_kw_flag).
 * mrbbc_find returns the number of the body a self call of self runs, or raises ArgumentError (wrong count) or
 * NoMethodError (no such method). mrbbc_find_send is an explicit receiver's call: it returns -1 when the method is not
 * the receiver's class's (the builtin path then runs), and raises NoMethodError for a top-level method, which is private.
 * mrbbc_find_init is the initialize of a new object (-1 when there is none and no argument was given). */
void mrbbc_def(const char *name, int id, long min, long max, int flags);
void mrbbc_def_in(const MV *cls, const char *name, int id, long min, long max, int flags);
int mrbbc_find(const MV *self, const char *name, long argc, long kw);
int mrbbc_find_send(const MV *recv, const char *name, long argc, long kw);
int mrbbc_find_init(const MV *obj, long argc, long kw);
/* SUPER: the method of the superclass of the class method number `method` is defined in, called on self (the name is
 * the one the TDEF gave). It returns -1 for the builtin initialize, which mrbbc_super_nil answers with nil. */
int mrbbc_find_super(const MV *self, int method, const char *name, long argc, long kw);
void mrbbc_super_nil(MV *dst);
void mrbbc_no_super(void) __attribute__((noreturn));

/* A call of the program's method number id from the runtime (the operators, to_s and inspect of an instance of a program
 * class), with argc arguments in argv[1..argc]. The lowered module defines it: one branch per method, as a self call has. */
void mrbbc_user_call(int id, MV *ret, MV *argv, MV *blk, long argc);

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

/* The parameters of a method (strict) or a block (not strict), as vm.c's ENTER binds them. R(1) is r1: the required (m1),
 * optional (o), rest (r, 0 or 1) and post (m2) parameters fill R(1..m1+o+r+m2) in order, the rest one with an array, and
 * the keyword hash (kd = 1) is R(m1+o+r+m2+1): the call's kw hash, or a new empty one. argv[0] is self and argv[1..argc]
 * the positional arguments (argv[argc+1] the keyword hash when kw is 1 and kd is 0, which then counts as positional). A
 * block of two or more parameters takes one array argument splatted (not strict). Returns the number of optional
 * parameters the call gave, which the body's jumps choose the defaults by. Nothing is checked here: the count is checked by
 * mrbbc_find. */
long mrbbc_bind(MV *r1, const MV *argv, long argc, long kw, long m1, long o, long r, long m2, long kd, long strict, long fast);
void mrbbc_ary_elt(MV *dst, const MV *ary, long i);

/* Keyword parameters (vm.c's KEY_P, KARG and KEYEND) on the kdict of a method: whether it has the key, its value (the key is
 * removed from the hash; "missing keyword" when it has none), and "unknown keyword" when keys are left over. */
void mrbbc_key_p(MV *dst, const MV *kdict, const char *name);
void mrbbc_karg(MV *dst, const MV *kdict, const char *name);
void mrbbc_keyend(const MV *kdict);

/* Hashes (HASH: dst = a new hash of the cap pairs to be set by mrbbc_hash_set; a key that is set again takes the new
 * value). Keys are compared by their value for symbols, integers and strings, and by identity otherwise. */
void mrbbc_hash_new(MV *dst, long cap);
void mrbbc_hash_set(MV *hash, const MV *key, const MV *value);
/* HASHCAT (`**h`): the pairs of a hash set into hash; any other value is a TypeError. mrbbc_kw_flag is the keyword flag of a
 * `**h` call: 1 when the hash has a key, 2 when it is empty. */
void mrbbc_hash_cat(MV *hash, const MV *src);
long mrbbc_kw_flag(const MV *h);
/* OP_AREF (`a, b = x`): an array's element i, or for a value that is not an array, the value at 0 and nil otherwise. */
void mrbbc_aref(MV *dst, const MV *v, long i);

/* Blocks. mrbbc_block makes the closure of a BLOCK at dst: it stores the block's number, a copy of self, the frame the
 * block was made in and its home (the frame of the method a return leaves), in clo (a 40-byte slot of the caller's
 * frame, the layout of Clo in mrbrt.c). The helpers read a block value: its number, its frame, its home, and argv[0] =
 * its self; mrbbc_blk_load copies the method's block (a nil one raises "unexpected yield"); mrbbc_blk_given writes true
 * or false for block_given?. A return out of a block is pending (mrbbc_return_block) until its home takes it. */
/* Blocks nested deeper than MRBBC_MAX_DEPTH are not lowered (their closure keeps that many frames). MRBBC_CLO_BYTES is the
 * size of the closure slot the lowering reserves for a BLOCK. A block made by a block (mrbbc_block_nested) gets the frames of
 * its creators: outer is the creator's %3 and pdisp its disp, of nd entries; mrbbc_blk_disp is a block's disp array, and
 * mrbbc_upframe(disp, k) the frame at upvar level k+1 of a block with that disp. */
#define MRBBC_MAX_DEPTH 8
#define MRBBC_CLO_BYTES 192
void mrbbc_block(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home);
void mrbbc_block_nested(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home, MV *outer, const MV *pdisp,
                        long nd);
MV *mrbbc_blk_disp(const MV *blk);
MV *mrbbc_upframe(const MV *disp, long k);
long mrbbc_blk_id(const MV *blk);
MV *mrbbc_blk_frame(const MV *blk);
MV *mrbbc_blk_home(const MV *blk);
void mrbbc_blk_args(MV *argv, const MV *blk);
void mrbbc_blk_load(MV *dst, const MV *blk);
void mrbbc_blk_given(MV *dst, const MV *blk);
/* `&nil` in a parameter list: a block given to the method raises ArgumentError "no block accepted". */
void mrbbc_noblock(const MV *blk);
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

/* Splats (vm.c's mrb_ary_splat, see mrbrt.c): dst = splat(v); ARYCAT appends splat(src) to dst (or takes it when dst is nil).
 * A splat call's arguments are the elements of an array: mrbbc_splat_argv gives a vector of self and those elements (its count
 * is mrbbc_ary_len of the array). */
void mrbbc_splat(MV *dst, const MV *v);
void mrbbc_ary_cat(MV *dst, const MV *src);
MV *mrbbc_splat_argv(const MV *self, const MV *ary);
long mrbbc_ary_len(const MV *ary);

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

/* Runs the program's entry (the lowered mrb_irep_0) under the collector: it records the C stack, calls entry with ret (its
 * result slot, a root while it runs), and turns the collector off when it returns. MRBBC_GC_THRESHOLD=N in the environment
 * forces a collection every N bytes of allocation (1: before every allocation). The collector is off outside mrbbc_run.
 * mrbbc_gc_collect collects now (a no-op outside mrbbc_run), mrbbc_gc_count is the number of objects allocated and not yet
 * swept, and mrbbc_gc_set_threshold forces the threshold to bytes (0 gives it back to the automatic one). */
void mrbbc_run(void (*entry)(MV *ret), MV *ret);
void mrbbc_gc_collect(void);
long mrbbc_gc_count(void);
void mrbbc_gc_set_threshold(long bytes);

#endif /* MRBBC_MRBRT_H */
