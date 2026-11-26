/* mrbrt: the runtime of the mruby bytecode producer (mrbrt.h). C99, -Wall -Wextra clean. The messages are the ones of the
 * pinned mruby 4.0.0 (probed with build/mruby-tool/bin/mruby; docs/notes/mrbbc-pathb.md, "Runtime errors"). */
#include "mrbrt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *mrbbc_progname = "mrbbc";

/* The checked 64-bit multiply of the IR (scripts/pathb-qbe-emit.rb calls it for cmul): the same function as in
 * be/nfcxx_ldrt.c, defined here so the test links without that runtime. Nonzero when the product overflows. */
int __nfcxx_smul64_ovf(long a, long b) {
  long r;
  return __builtin_mul_overflow(a, b, &r);
}

/* Heap objects. A string is one block: the length and the bytes, then a NUL. An array is a header and its items. */
typedef struct MStr {
  long len;
  char p[];
} MStr;

/* A growable byte buffer for inspect and to_s. */
typedef struct Buf {
  char *p;
  size_t n, cap;
} Buf;

static void inspect_value(Buf *b, const MV *v);
static MV to_s_string(const MV *v);

typedef struct MAry {
  long len, cap;
  MV *items;
} MAry;

/* Classes and objects. A method of the program is an MDef in the list of its class (newest first, so a redefinition wins),
 * and a top-level one is in object_class's list. A class has its name (the full one, A::B for a nested class), the key
 * GETCONST and CLASS find it by (the plain name), its class-level instance variables, and the next class of the registry.
 * An object is its class and its instance variables. Heap objects are malloc'd and never freed, as the rest. */
typedef struct MDef {
  const char *name;
  int id;
  long arity;
  struct MDef *next;
} MDef;

typedef struct MIvar {
  const char *name;
  MV val;
  struct MIvar *next;
} MIvar;

typedef struct MClass {
  const char *key, *name;
  MDef *defs;
  MIvar *ivars;
  struct MClass *super; /* the superclass: Object for a class made without one, NULL for Object itself */
  struct MClass *next;
} MClass;

typedef struct MObj {
  MClass *cls;
  MIvar *ivars;
} MObj;

static MClass object_class = {"Object", "Object", NULL, NULL, NULL, NULL};
static MClass *class_registry = NULL;

/* The class each method body is defined on, by the method's number (the TDEF's class; Object for a top-level def). A SUPER
 * looks from the superclass of that class. */
static MClass **owners = NULL;
static int owners_n = 0;

static void set_owner(int id, MClass *c) {
  int k;
  if (id >= owners_n) {
    MClass **p = realloc(owners, (size_t)(id + 1) * sizeof *p);
    if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
    owners = p;
    for (k = owners_n; k <= id; k++) owners[k] = NULL;
    owners_n = id + 1;
  }
  owners[id] = c;
}

void mrbbc_raise(const char *cls, const char *message) {
  fflush(stdout);
  fprintf(stderr, "%s: %s (%s)\n", mrbbc_progname, message, cls);
  exit(1);
}

static void *alloc(size_t n) {
  void *p = malloc(n);
  if (p == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  return p;
}

static MStr *str_of(const MV *v) { return (MStr *)(intptr_t)v->i; }
static MAry *ary_of(const MV *v) { return (MAry *)(intptr_t)v->i; }
static const char *sym_of(const MV *v) { return (const char *)(intptr_t)v->i; }

static void set_obj(MV *dst, int tag, const void *p) {
  dst->tag = (uint8_t)tag;
  dst->i = (int64_t)(intptr_t)p;
}

static MV new_str_value(const char *p, long n) {
  MStr *s = alloc(sizeof(MStr) + (size_t)n + 1);
  MV v;
  s->len = n;
  if (n > 0) memcpy(s->p, p, (size_t)n);
  s->p[n] = '\0';
  set_obj(&v, MRBBC_STR, s);
  return v;
}

static MV int_value(int64_t i) {
  MV v;
  v.tag = MRBBC_INT;
  v.i = i;
  return v;
}

static MV bool_value(int truth) {
  MV v;
  v.tag = truth ? MRBBC_TRUE : MRBBC_FALSE;
  v.i = 0;
  return v;
}

void mrbbc_set_bool(MV *dst, int truth) { *dst = bool_value(truth); }

void mrbbc_str_new(MV *dst, const char *p, long n) {
  MV v = new_str_value(p, n);
  *dst = v;
}

void mrbbc_sym(MV *dst, const char *name) { set_obj(dst, MRBBC_SYM, name); }
static const char *class_name(const MV *v);

/* The methods and classes of the program (see MDef and MClass above). mrbbc_def and mrbbc_def_in add an entry to the list
 * of Object or of a class, so a redefinition wins. A self call (mrbbc_find) looks in the class of self when self is an
 * object, then in Object. An explicit receiver's call (mrbbc_find_send) looks in the receiver's class only: a top-level
 * method is private, so reaching one of those with an explicit receiver is a NoMethodError. A wrong argument count is an
 * ArgumentError and a name nothing defines a NoMethodError. */
static void add_def(MDef **head, const char *name, int id, long arity) {
  MDef *d = alloc(sizeof *d);
  d->name = name;
  d->id = id;
  d->arity = arity;
  d->next = *head;
  *head = d;
}

static MDef *find_def(MDef *d, const char *name) {
  for (; d != NULL; d = d->next) {
    if (strcmp(d->name, name) == 0) return d;
  }
  return NULL;
}

static int check_arity(const MDef *d, long argc) {
  if (d->arity != argc) {
    char msg[128];
    snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected %ld)", argc, d->arity);
    mrbbc_raise("ArgumentError", msg);
  }
  return d->id;
}

static MClass *cls_of(const MV *v) { return (MClass *)(intptr_t)v->i; }
static MObj *obj_of(const MV *v) { return (MObj *)(intptr_t)v->i; }

/* The first method of the name on c or its superclasses (every chain ends at Object). where gets the class it is found in. */
static MDef *find_chain(MClass *c, const char *name, MClass **where) {
  for (; c != NULL; c = c->super) {
    MDef *d = find_def(c->defs, name);
    if (d != NULL) {
      if (where != NULL) *where = c;
      return d;
    }
  }
  return NULL;
}

void mrbbc_def(const char *name, int id, long arity) {
  add_def(&object_class.defs, name, id, arity);
  set_owner(id, &object_class);
}

void mrbbc_def_in(const MV *cls, const char *name, int id, long arity) {
  if (cls->tag != MRBBC_CLS) mrbbc_raise("TypeError", "a method is defined on a class");
  add_def(&cls_of(cls)->defs, name, id, arity);
  set_owner(id, cls_of(cls));
}

int mrbbc_find(const MV *self, const char *name, long argc) {
  MClass *start = self->tag == MRBBC_OBJ ? obj_of(self)->cls : &object_class;
  MDef *d = find_chain(start, name, NULL);
  if (d != NULL) return check_arity(d, argc);
  {
    char msg[256];
    const char *cname = self->tag == MRBBC_OBJ ? obj_of(self)->cls->name : "Object";
    snprintf(msg, sizeof msg, "undefined method '%s' for %s", name, cname);
    mrbbc_raise("NoMethodError", msg);
  }
}

static void private_error(const MV *recv, const char *name) __attribute__((noreturn));

static void private_error(const MV *recv, const char *name) {
  char msg[256];
  snprintf(msg, sizeof msg, "private method '%s' called for %s", name, class_name(recv));
  mrbbc_raise("NoMethodError", msg);
}

int mrbbc_find_send(const MV *recv, const char *name, long argc) {
  if (recv->tag == MRBBC_OBJ) {
    MClass *where = NULL;
    MDef *d = find_chain(obj_of(recv)->cls, name, &where);
    if (d == NULL) return -1;
    if (where == &object_class) private_error(recv, name);  /* a top-level def is a private method of Object */
    return check_arity(d, argc);
  }
  if (recv->tag == MRBBC_CLS && find_def(object_class.defs, name) != NULL) private_error(recv, name);
  return -1;
}

int mrbbc_find_super(const MV *self, int method, const char *name, long argc) {
  MClass *owner = method >= 0 && method < owners_n ? owners[method] : NULL;
  MDef *d = owner != NULL ? find_chain(owner->super, name, NULL) : NULL;
  if (d != NULL) return check_arity(d, argc);
  if (strcmp(name, "initialize") == 0) {
    if (argc != 0) {
      char msg[128];
      snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected 0)", argc);
      mrbbc_raise("ArgumentError", msg);
    }
    return -1;
  }
  {
    /* the methods of Object, Kernel and Comparable that mruby has builtin: not lowered, so not a NoMethodError */
    static const char *const builtins[] = {
        "to_s", "inspect", "==", "!=", "!", "equal?", "eql?", "hash", "class", "nil?", "is_a?", "kind_of?", "instance_of?",
        "respond_to?", "send", "method", "methods", "freeze", "frozen?", "dup", "clone", "object_id", "p", "puts", "print",
        "raise", "loop", "format", "sprintf", "lambda", "proc", "block_given?", "require"};
    char msg[256];
    const char *cname = self->tag == MRBBC_OBJ ? obj_of(self)->cls->name : "Object";
    size_t k;
    for (k = 0; k < sizeof builtins / sizeof builtins[0]; k++) {
      if (strcmp(builtins[k], name) == 0) {
        snprintf(msg, sizeof msg, "super of the builtin method '%s' is not lowered yet", name);
        mrbbc_raise("NotImplementedError", msg);
      }
    }
    snprintf(msg, sizeof msg, "super: no superclass method '%s' for %s", name, cname);
    mrbbc_raise("NoMethodError", msg);
  }
}

void mrbbc_super_nil(MV *dst) {
  dst->tag = MRBBC_NIL;
  dst->i = 0;
}

int mrbbc_find_init(const MV *obj, long argc) {
  MDef *d = find_chain(obj_of(obj)->cls, "initialize", NULL);
  if (d != NULL) return check_arity(d, argc);
  if (argc != 0) {
    char msg[128];
    snprintf(msg, sizeof msg, "wrong number of arguments (given %ld, expected 0)", argc);
    mrbbc_raise("ArgumentError", msg);
  }
  return -1;
}

static MClass *find_class(const char *key) {
  MClass *c;
  for (c = class_registry; c != NULL; c = c->next) {
    if (strcmp(c->key, key) == 0) return c;
  }
  return NULL;
}

/* The names of the classes and modules of mruby's core: the program does not reopen or read them (not lowered). */
static int core_name(const char *name) {
  static const char *const names[] = {
      "Object",    "BasicObject", "Module",    "Class",          "Kernel",    "Comparable", "Enumerable",
      "NilClass",  "TrueClass",   "FalseClass", "Integer",        "Float",     "String",     "Symbol",
      "Array",     "Hash",        "Range",     "Proc",           "Exception", "StandardError", "NameError",
      "NoMethodError", "ArgumentError", "TypeError", "ZeroDivisionError", "IndexError", "RuntimeError",
      "LocalJumpError", "NotImplementedError", "Math", "Struct", "Time"};
  size_t i;
  for (i = 0; i < sizeof names / sizeof names[0]; i++) {
    if (strcmp(names[i], name) == 0) return 1;
  }
  return 0;
}

void mrbbc_class(MV *dst, const MV *cbase, const MV *super, const char *name, const MV *target) {
  MClass *outer = &object_class, *c, *sup = NULL;
  if (super->tag != MRBBC_NIL) {
    char msg[160];
    if (super->tag != MRBBC_CLS) {
      Buf b = {NULL, 0, 0};
      if (super->tag == MRBBC_OBJ) mrbbc_raise("NotImplementedError", "a superclass that is an instance is not lowered yet");
      inspect_value(&b, super);
      snprintf(msg, sizeof msg, "superclass must be a Class (%s given)", b.p);
      free(b.p);
      mrbbc_raise("TypeError", msg);
    }
    sup = cls_of(super);
  }
  if (cbase->tag == MRBBC_CLS) {
    outer = cls_of(cbase);
  } else if (target->tag == MRBBC_CLS) {
    outer = cls_of(target);
  }
  c = find_class(name);
  if (c == NULL) {
    if (core_name(name)) mrbbc_raise("NotImplementedError", "reopening a core class is not lowered yet");
    c = alloc(sizeof *c);
    c->key = name;
    if (outer == &object_class) {
      c->name = name;
    } else {
      size_t n = strlen(outer->name) + 2 + strlen(name) + 1;
      char *full = alloc(n);
      snprintf(full, n, "%s::%s", outer->name, name);
      c->name = full;
    }
    c->defs = NULL;
    c->ivars = NULL;
    c->super = sup != NULL ? sup : &object_class;
    c->next = class_registry;
    class_registry = c;
  } else if (sup != NULL && c->super != sup) {
    char msg[256];
    snprintf(msg, sizeof msg, "superclass mismatch for %s", c->name);
    mrbbc_raise("TypeError", msg);
  }
  set_obj(dst, MRBBC_CLS, c);
}

void mrbbc_object_class(MV *dst) { set_obj(dst, MRBBC_CLS, &object_class); }

void mrbbc_getconst(MV *dst, const char *name) {
  MClass *c = find_class(name);
  if (c == NULL && strcmp(name, "Object") == 0) c = &object_class;
  if (c != NULL) {
    set_obj(dst, MRBBC_CLS, c);
    return;
  }
  if (core_name(name)) mrbbc_raise("NotImplementedError", "a core constant is not lowered yet");
  {
    char msg[256];
    snprintf(msg, sizeof msg, "uninitialized constant %s", name);
    mrbbc_raise("NameError", msg);
  }
}

void mrbbc_alloc(MV *dst, const MV *cls) {
  MObj *o;
  if (cls->tag != MRBBC_CLS) mrbbc_no_method(cls, "new");
  o = alloc(sizeof *o);
  o->cls = cls_of(cls);
  o->ivars = NULL;
  set_obj(dst, MRBBC_OBJ, o);
}

static MIvar **ivars_of(const MV *self) {
  if (self->tag == MRBBC_OBJ) return &obj_of(self)->ivars;
  if (self->tag == MRBBC_CLS) return &cls_of(self)->ivars;
  return NULL;
}

void mrbbc_getiv(MV *dst, const MV *self, const char *name) {
  MIvar **head = ivars_of(self), *v;
  MV out;
  out.tag = MRBBC_NIL;
  out.i = 0;
  if (head != NULL) {
    for (v = *head; v != NULL; v = v->next) {
      if (strcmp(v->name, name) == 0) {
        out = v->val;
        break;
      }
    }
  }
  *dst = out;
}

void mrbbc_setiv(const MV *self, const char *name, const MV *val) {
  MIvar **head = ivars_of(self), *v;
  if (head == NULL) mrbbc_raise("NotImplementedError", "an instance variable of this value is not lowered yet");
  for (v = *head; v != NULL; v = v->next) {
    if (strcmp(v->name, name) == 0) {
      v->val = *val;
      return;
    }
  }
  v = alloc(sizeof *v);
  v->name = name;
  v->val = *val;
  v->next = *head;
  *head = v;
}


/* A block value (MRBBC_BLK): the int64 is the Clo that mrbbc_block fills. The layout is 40 bytes, as the producer
 * reserves it (tools/mrbbc/mrb_lower.cpp, the BLOCK slot). A closure lives in its frame, which is alive while the block
 * can be yielded: a block is passed to a method and not kept (a block parameter is refused). home is the frame of the
 * method the block was made in (the frame a return out of the block leaves). */
typedef struct Clo {
  long id;
  MV self;
  MV *frame;
  MV *home;
} Clo;

static Clo *clo_of(const MV *v) { return (Clo *)(intptr_t)v->i; }

void mrbbc_block(MV *dst, void *clo, long id, const MV *self, MV *frame, MV *home) {
  Clo *c = clo;
  c->id = id;
  c->self = *self;
  c->frame = frame;
  c->home = home;
  set_obj(dst, MRBBC_BLK, c);
}

long mrbbc_blk_id(const MV *blk) {
  if (blk->tag != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->id;
}

MV *mrbbc_blk_frame(const MV *blk) {
  if (blk->tag != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->frame;
}

MV *mrbbc_blk_home(const MV *blk) {
  if (blk->tag != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  return clo_of(blk)->home;
}

/* A return out of a block. The value is pending for home: every call on the way returns at once (mrbbc_unwinding is
 * checked after each call of a method or a block) until the function whose frame is home takes it (mrbbc_unwind_take),
 * and that function returns the value. */
static int unwind_pending = 0;
static int unwind_break = 0; /* the pending exit is a break (its home is the frame of the call the block was passed to) */
static MV *unwind_home = NULL;
static MV unwind_value;

void mrbbc_return_block(const MV *value, MV *home) {
  unwind_pending = 1;
  unwind_break = 0;
  unwind_home = home;
  unwind_value = *value;
}

/* A break out of a block: the call that the block was passed to (the frame that made the block, home) returns value. */
void mrbbc_break(const MV *value, MV *home) {
  unwind_pending = 1;
  unwind_break = 1;
  unwind_home = home;
  unwind_value = *value;
}

int mrbbc_unwinding(void) { return unwind_pending; }

void mrbbc_unwind_take(MV *ret, MV *frame) {
  if (unwind_pending && !unwind_break && unwind_home == frame) {
    *ret = unwind_value;
    unwind_pending = 0;
  }
}

/* Takes a pending break whose home is frame: dst gets its value, and the caller goes on after the call. */
int mrbbc_break_take(MV *dst, MV *frame) {
  if (unwind_pending && unwind_break && unwind_home == frame) {
    *dst = unwind_value;
    unwind_pending = 0;
    unwind_break = 0;
    return 1;
  }
  return 0;
}

int mrbbc_splats(const MV *argv, long argc) { return argc == 1 && argv[1].tag == MRBBC_ARY; }

void mrbbc_ary_elt(MV *dst, const MV *ary, long i) {
  const MAry *a = ary_of(ary);
  MV out;
  out.tag = MRBBC_NIL;
  out.i = 0;
  if (i < a->len) out = a->items[i];
  *dst = out;
}

/* OP_AREF as vm.c does it: an array gives its element i (nil past its end); any other value is itself at i = 0 and nil
 * otherwise (the destructuring `a, b = x` of a value that is not an array). */
void mrbbc_aref(MV *dst, const MV *v, long i) {
  MV src = *v;
  if (src.tag == MRBBC_ARY) {
    mrbbc_ary_elt(dst, &src, i);
    return;
  }
  if (i == 0) *dst = src;
  else {
    dst->tag = MRBBC_NIL;
    dst->i = 0;
  }
}

void mrbbc_blk_args(MV *argv, const MV *blk) {
  if (blk->tag != MRBBC_BLK) mrbbc_raise("LocalJumpError", "unexpected yield");
  argv[0] = clo_of(blk)->self;
}

void mrbbc_blk_load(MV *dst, const MV *blk) {
  if (blk->tag == MRBBC_NIL) mrbbc_raise("LocalJumpError", "unexpected yield");
  *dst = *blk;
}

void mrbbc_blk_given(MV *dst, const MV *blk) {
  dst->tag = blk->tag == MRBBC_NIL ? MRBBC_FALSE : MRBBC_TRUE;
  dst->i = 0;
}

/* The class of a value, as NoMethodError and ArgumentError name it. */
static const char *class_name(const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: return "NilClass";
    case MRBBC_TRUE: return "TrueClass";
    case MRBBC_FALSE: return "FalseClass";
    case MRBBC_STR: return "String";
    case MRBBC_ARY: return "Array";
    case MRBBC_SYM: return "Symbol";
    case MRBBC_OBJ: return obj_of(v)->cls->name;
    case MRBBC_CLS: return "Class";
    case MRBBC_BLK: return "Proc";
    default: return "Integer";
  }
}

/* What a TypeError shows for an operand: nil, true and false by their names, anything else by its class. */
static const char *type_text(const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: return "nil";
    case MRBBC_TRUE: return "true";
    case MRBBC_FALSE: return "false";
    default: return class_name(v);
  }
}

static const char *op_method(int op) {
  switch (op) {
    case MRBBC_OP_ADD: return "+";
    case MRBBC_OP_SUB: return "-";
    case MRBBC_OP_MUL: return "*";
    case MRBBC_OP_DIV: return "/";
    case MRBBC_OP_LT: return "<";
    case MRBBC_OP_LE: return "<=";
    case MRBBC_OP_GT: return ">";
    case MRBBC_OP_GE: return ">=";
    case MRBBC_OP_NEQ: return "!=";
    default: return "==";
  }
}

static void no_method(const char *name, const MV *recv) __attribute__((noreturn));

static void no_method(const char *name, const MV *recv) {
  char msg[160];
  snprintf(msg, sizeof msg, "undefined method '%s' for %s", name, class_name(recv));
  mrbbc_raise("NoMethodError", msg);
}

void mrbbc_no_method(const MV *recv, const char *name) { no_method(name, recv); }

/* The program's method of the name for an instance, found on its class and the superclasses (-1 when there is none, and
 * for any other value: only an instance of a program class has methods of the program). A wrong count is an ArgumentError. */
static int user_method(const MV *recv, const char *name, long argc) {
  MDef *d;
  if (recv->tag != MRBBC_OBJ) return -1;
  d = find_chain(obj_of(recv)->cls, name, NULL);
  return d == NULL ? -1 : check_arity(d, argc);
}

/* Calls the program's method id on recv, with the argument arg (none when arg is NULL). The result goes to ret, which may
 * be recv's own slot: the arguments are copied first. */
static void call_user(MV *ret, int id, const MV *recv, const MV *arg) {
  MV argv[2], blk;
  argv[0] = *recv;
  argv[1] = arg != NULL ? *arg : *recv;
  blk.tag = MRBBC_NIL;
  blk.i = 0;
  mrbbc_user_call(id, ret, argv, &blk);
}

static void buf_put(Buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 64;
    char *p;
    while (b->n + n + 1 > cap) cap *= 2;
    p = alloc(cap);
    if (b->n) memcpy(p, b->p, b->n);
    free(b->p);
    b->p = p;
    b->cap = cap;
  }
  if (n) memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = '\0';
}

static void buf_str(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_char(Buf *b, char c) { buf_put(b, &c, 1); }

/* String#inspect of this build (byte strings): the named escapes, \# before #{ #$ #@, \xHH for other bytes that are
 * not printable ASCII. */
static void inspect_bytes(Buf *b, const char *s, long n) {
  long k;
  buf_char(b, '"');
  for (k = 0; k < n; k++) {
    unsigned char c = (unsigned char)s[k];
    switch (c) {
      case '"': buf_str(b, "\\\""); break;
      case '\\': buf_str(b, "\\\\"); break;
      case '\n': buf_str(b, "\\n"); break;
      case '\r': buf_str(b, "\\r"); break;
      case '\t': buf_str(b, "\\t"); break;
      case '\f': buf_str(b, "\\f"); break;
      case '\v': buf_str(b, "\\v"); break;
      case '\b': buf_str(b, "\\b"); break;
      case '\a': buf_str(b, "\\a"); break;
      case 0x1b: buf_str(b, "\\e"); break;
      case '#':
        if (k + 1 < n && (s[k + 1] == '{' || s[k + 1] == '$' || s[k + 1] == '@')) buf_str(b, "\\#");
        else buf_char(b, '#');
        break;
      default:
        if (c >= 0x20 && c < 0x7f) {
          buf_char(b, (char)c);
        } else {
          char h[8];
          snprintf(h, sizeof h, "\\x%02x", (unsigned)c);
          buf_str(b, h);
        }
    }
  }
  buf_char(b, '"');
}

/* The arrays being inspected, so that an array that contains itself prints as mruby prints it ("[...]"). */
#define INSPECT_DEPTH 64
static const MAry *inspecting[INSPECT_DEPTH];
static int inspect_depth;

static void inspect_value(Buf *b, const MV *v) {
  switch (v->tag) {
    case MRBBC_NIL: buf_str(b, "nil"); break;
    case MRBBC_TRUE: buf_str(b, "true"); break;
    case MRBBC_FALSE: buf_str(b, "false"); break;
    case MRBBC_INT: {
      char h[32];
      snprintf(h, sizeof h, "%lld", (long long)v->i);
      buf_str(b, h);
      break;
    }
    case MRBBC_STR: inspect_bytes(b, str_of(v)->p, str_of(v)->len); break;
    case MRBBC_SYM:
      buf_char(b, ':');
      buf_str(b, sym_of(v));
      break;
    case MRBBC_CLS: buf_str(b, cls_of(v)->name); break;
    case MRBBC_OBJ: {
      /* the program's inspect, as the p of an instance calls it; the default one prints an address, which is not lowered */
      MV r;
      MV s;
      int id = user_method(v, "inspect", 0);
      if (id < 0) mrbbc_raise("NotImplementedError", "inspect of an instance is not lowered yet");
      call_user(&r, id, v, NULL);
      s = to_s_string(&r);
      buf_put(b, str_of(&s)->p, (size_t)str_of(&s)->len);
      break;
    }
    case MRBBC_ARY: {
      const MAry *a = ary_of(v);
      long k;
      int i, seen = 0, pushed;
      for (i = 0; i < inspect_depth; i++) {
        if (inspecting[i] == a) seen = 1;
      }
      if (seen) {
        buf_str(b, "[...]");
        break;
      }
      buf_char(b, '[');
      pushed = inspect_depth < INSPECT_DEPTH;
      if (pushed) inspecting[inspect_depth++] = a;
      for (k = 0; k < a->len; k++) {
        if (k) buf_str(b, ", ");
        inspect_value(b, &a->items[k]);
      }
      if (pushed) inspect_depth--;
      buf_char(b, ']');
      break;
    }
    default: mrbbc_raise("RuntimeError", "unknown value tag");
  }
}

void mrbbc_print(const MV *v) {
  Buf b = {NULL, 0, 0};
  inspect_value(&b, v);
  buf_char(&b, '\n');
  fwrite(b.p, 1, b.n, stdout);
  free(b.p);
}

/* a == b (mruby's ==, for these values). Arrays compare element by element. An instance is equal to itself (rb_equal checks
 * identity first), and otherwise its class's == decides when the program defines one (a truthy result is equal). */
static int value_eq(const MV *a, const MV *b) {
  if (a->tag == MRBBC_OBJ) {
    MV r;
    int id;
    if (a->tag == b->tag && a->i == b->i) return 1;
    id = user_method(a, "==", 1);
    if (id < 0) return 0;
    call_user(&r, id, a, b);
    return r.tag != MRBBC_NIL && r.tag != MRBBC_FALSE;
  }
  if (a->tag != b->tag) return 0;
  switch (a->tag) {
    case MRBBC_INT: return a->i == b->i;
    case MRBBC_STR: return str_of(a)->len == str_of(b)->len && memcmp(str_of(a)->p, str_of(b)->p, (size_t)str_of(a)->len) == 0;
    case MRBBC_SYM: return strcmp(sym_of(a), sym_of(b)) == 0;
    case MRBBC_CLS: return a->i == b->i;  /* identity */
    case MRBBC_ARY: {
      const MAry *x = ary_of(a), *y = ary_of(b);
      long k;
      if (x == y) return 1;
      if (x->len != y->len) return 0;
      for (k = 0; k < x->len; k++) {
        if (!value_eq(&x->items[k], &y->items[k])) return 0;
      }
      return 1;
    }
    default: return 1;  /* nil, true, false */
  }
}

/* The order of two strings (memcmp, then the lengths), as String#<=> gives its sign. */
static int str_order(const MV *a, const MV *b) {
  long n = str_of(a)->len < str_of(b)->len ? str_of(a)->len : str_of(b)->len;
  int c = n ? memcmp(str_of(a)->p, str_of(b)->p, (size_t)n) : 0;
  if (c) return c;
  return str_of(a)->len < str_of(b)->len ? -1 : str_of(a)->len > str_of(b)->len;
}

static int compare_result(int op, int c) {
  switch (op) {
    case MRBBC_OP_LT: return c < 0;
    case MRBBC_OP_LE: return c <= 0;
    case MRBBC_OP_GT: return c > 0;
    default: return c >= 0;  /* GE */
  }
}

/* Array storage: room for at least need items. */
static void ary_reserve(MAry *a, long need) {
  if (need <= a->cap) return;
  long cap = a->cap ? a->cap : 4;
  MV *items;
  while (cap < need) cap *= 2;
  items = realloc(a->items, (size_t)cap * sizeof(MV));
  if (items == NULL) mrbbc_raise("NoMemoryError", "failed to allocate memory");
  a->items = items;
  a->cap = cap;
}

static MV new_ary_value(long cap) {
  MAry *a = alloc(sizeof(MAry));
  MV v;
  a->len = 0;
  a->cap = 0;
  a->items = NULL;
  ary_reserve(a, cap > 0 ? cap : 0);
  set_obj(&v, MRBBC_ARY, a);
  return v;
}

void mrbbc_ary_new(MV *dst, long cap) {
  MV v = new_ary_value(cap);
  *dst = v;
}

void mrbbc_ary_push(MV *ary, const MV *v) {
  MAry *a;
  MV item = *v;
  if (ary->tag != MRBBC_ARY) mrbbc_raise("TypeError", "expected Array");
  a = ary_of(ary);
  ary_reserve(a, a->len + 1);
  a->items[a->len++] = item;
}

static int64_t floor_div(int64_t x, int64_t y) {
  int64_t q = x / y;
  if ((x % y != 0) && ((x < 0) != (y < 0))) q -= 1;
  return q;
}

/* Integer on the left. The integer operators are exact up to overflow, which traps (see the header). */
static void int_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  int64_t r = 0;
  MV out;

  if (b->tag != MRBBC_INT) {
    if (op >= MRBBC_OP_LT) {
      snprintf(msg, sizeof msg, "comparison of Integer with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    if (op == MRBBC_OP_ADD || op == MRBBC_OP_SUB) {
      if (b->tag == MRBBC_NIL) mrbbc_raise("TypeError", "can't convert nil into Float");
      snprintf(msg, sizeof msg, "%s cannot be converted to Float", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    snprintf(msg, sizeof msg, "can't convert %s into Integer", type_text(b));
    mrbbc_raise("TypeError", msg);
  }

  switch (op) {
    case MRBBC_OP_ADD:
      if (__builtin_add_overflow(a->i, b->i, &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_SUB:
      if (__builtin_sub_overflow(a->i, b->i, &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_MUL:
      if (__builtin_mul_overflow(a->i, b->i, &r)) break;
      *dst = int_value(r);
      return;
    case MRBBC_OP_DIV:
      if (b->i == 0) mrbbc_raise("ZeroDivisionError", "divided by 0");
      if (a->i == INT64_MIN && b->i == -1) break;
      *dst = int_value(floor_div(a->i, b->i));
      return;
    default:
      out = bool_value(compare_result(op, a->i < b->i ? -1 : a->i > b->i));
      *dst = out;
      return;
  }
  /* Only an integer overflow gets here. mruby promotes it to a Bignum (or a Float); this producer does not. */
  mrbbc_raise("NotImplementedError", "integer overflow: mrbbc does not promote to Bignum");
}

/* String on the left: + (concatenation), * (repetition) and the comparisons. */
static void str_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  MV out;
  if (op == MRBBC_OP_ADD) {
    long la, lb;
    MStr *t;
    if (b->tag != MRBBC_STR) {
      snprintf(msg, sizeof msg, "%s cannot be converted to String", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    la = str_of(a)->len;
    lb = str_of(b)->len;
    t = alloc(sizeof(MStr) + (size_t)(la + lb) + 1);
    memcpy(t->p, str_of(a)->p, (size_t)la);
    memcpy(t->p + la, str_of(b)->p, (size_t)lb);
    t->p[la + lb] = '\0';
    t->len = la + lb;
    set_obj(&out, MRBBC_STR, t);
    *dst = out;
    return;
  }
  if (op == MRBBC_OP_MUL) {
    long n, len, k;
    MStr *t;
    if (b->tag != MRBBC_INT) {
      snprintf(msg, sizeof msg, "%s cannot be converted to Integer", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    if (b->i < 0) mrbbc_raise("ArgumentError", "negative argument");
    n = (long)b->i;
    len = str_of(a)->len;
    if (n != 0 && len > (long)(((size_t)-1 >> 1) / (size_t)n)) mrbbc_raise("ArgumentError", "argument too big");
    t = alloc(sizeof(MStr) + (size_t)(len * n) + 1);
    for (k = 0; k < n; k++) memcpy(t->p + k * len, str_of(a)->p, (size_t)len);
    t->p[len * n] = '\0';
    t->len = len * n;
    set_obj(&out, MRBBC_STR, t);
    *dst = out;
    return;
  }
  if (op >= MRBBC_OP_LT) {
    if (b->tag != MRBBC_STR) {
      snprintf(msg, sizeof msg, "comparison of String with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    out = bool_value(compare_result(op, str_order(a, b)));
    *dst = out;
    return;
  }
  no_method(op_method(op), a);
}

/* Array on the left: + (concatenation). The other operators of Array are not in this runtime. */
static void ary_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  if (op == MRBBC_OP_ADD) {
    MV r;
    MAry *x, *y, *z;
    long k;
    if (b->tag != MRBBC_ARY) {
      snprintf(msg, sizeof msg, "%s cannot be converted to Array", type_text(b));
      mrbbc_raise("TypeError", msg);
    }
    x = ary_of(a);
    y = ary_of(b);
    r = new_ary_value(x->len + y->len);
    z = ary_of(&r);
    for (k = 0; k < x->len; k++) z->items[z->len++] = x->items[k];
    for (k = 0; k < y->len; k++) z->items[z->len++] = y->items[k];
    *dst = r;
    return;
  }
  if (op == MRBBC_OP_SUB || op == MRBBC_OP_MUL) {
    snprintf(msg, sizeof msg, "Array#%s is not implemented by mrbbc", op_method(op));
    mrbbc_raise("NotImplementedError", msg);
  }
  no_method(op_method(op), a);
}

/* Symbol on the left: the comparisons (by name), as Symbol includes Comparable. */
static void sym_op(int op, MV *dst, const MV *a, const MV *b) {
  char msg[160];
  if (op >= MRBBC_OP_LT) {
    int c;
    if (b->tag != MRBBC_SYM) {
      snprintf(msg, sizeof msg, "comparison of Symbol with %s failed", class_name(b));
      mrbbc_raise("ArgumentError", msg);
    }
    c = strcmp(sym_of(a), sym_of(b));
    *dst = bool_value(compare_result(op, c));
    return;
  }
  no_method(op_method(op), a);
}

/* An operator on an instance: the program's method of the operator's name (its result is the operator's, as mruby's
 * dispatch gives it). Without one, == and != are identity (and != negates a == the program defines), and the rest is a
 * NoMethodError. */
static void obj_op(int op, MV *dst, const MV *a, const MV *b) {
  int id = user_method(a, op_method(op), 1);
  if (id >= 0) {
    call_user(dst, id, a, b);
    return;
  }
  if (op == MRBBC_OP_EQ || op == MRBBC_OP_NEQ) {
    int eq = value_eq(a, b);
    *dst = bool_value(op == MRBBC_OP_EQ ? eq : !eq);
    return;
  }
  no_method(op_method(op), a);
}

void mrbbc_binop(int op, MV *dst, const MV *a, const MV *b) {
  if (a->tag == MRBBC_OBJ) {
    obj_op(op, dst, a, b);
    return;
  }
  if (op == MRBBC_OP_EQ || op == MRBBC_OP_NEQ) {
    int eq = value_eq(a, b);
    *dst = bool_value(op == MRBBC_OP_EQ ? eq : !eq);
    return;
  }
  switch (a->tag) {
    case MRBBC_INT: int_op(op, dst, a, b); return;
    case MRBBC_STR: str_op(op, dst, a, b); return;
    case MRBBC_ARY: ary_op(op, dst, a, b); return;
    case MRBBC_SYM: sym_op(op, dst, a, b); return;
    default: no_method(op_method(op), a);  /* nil, true, false */
  }
}

/* The index of an element: a negative index counts from the end. Returns false when it is below zero after that. */
static int ary_index(const MAry *a, long idx, long *out) {
  long i = idx;
  if (i < 0) i += a->len;
  if (i < 0) return 0;
  *out = i;
  return 1;
}

void mrbbc_getidx(MV *dst, const MV *recv, const MV *idx) {
  MV r;
  r.tag = MRBBC_NIL;
  r.i = 0;
  if (recv->tag == MRBBC_ARY && idx->tag == MRBBC_INT) {
    const MAry *a = ary_of(recv);
    long i;
    if (ary_index(a, (long)idx->i, &i) && i < a->len) r = a->items[i];
    *dst = r;
    return;
  }
  if (recv->tag == MRBBC_STR && idx->tag == MRBBC_INT) {
    const MStr *s = str_of(recv);
    long i = (long)idx->i;
    if (i < 0) i += s->len;
    if (i >= 0 && i < s->len) r = new_str_value(s->p + i, 1);
    *dst = r;
    return;
  }
  if (recv->tag == MRBBC_ARY || recv->tag == MRBBC_STR) {
    mrbbc_raise("NotImplementedError", "[] with a non-integer index is not implemented by mrbbc");
  }
  no_method("[]", recv);
}

void mrbbc_getidx0(MV *dst, const MV *recv) {
  MV zero = int_value(0);
  mrbbc_getidx(dst, recv, &zero);
}

void mrbbc_setidx(const MV *recv, const MV *idx, const MV *v) {
  MAry *a;
  long i;
  MV item = *v;
  if (recv->tag != MRBBC_ARY) {
    if (recv->tag == MRBBC_STR) mrbbc_raise("NotImplementedError", "String#[]= is not implemented by mrbbc");
    no_method("[]=", recv);
  }
  if (idx->tag != MRBBC_INT) mrbbc_raise("NotImplementedError", "[]= with a non-integer index is not implemented by mrbbc");
  a = ary_of(recv);
  i = (long)idx->i;
  if (i < 0) {
    char msg[96];
    if (i + a->len < 0) {
      snprintf(msg, sizeof msg, "index %ld out of array", i);
      mrbbc_raise("IndexError", msg);
    }
    i += a->len;
  }
  if (i >= a->len) {
    long k;
    ary_reserve(a, i + 1);
    for (k = a->len; k <= i; k++) {
      a->items[k].tag = MRBBC_NIL;
      a->items[k].i = 0;
    }
    a->len = i + 1;
  }
  a->items[i] = item;
}

void mrbbc_strcat(MV *dst, const MV *src) {
  Buf b = {NULL, 0, 0};
  MV out;
  const MStr *s;
  if (dst->tag != MRBBC_STR) mrbbc_raise("TypeError", "expected String");
  s = str_of(dst);
  /* the operand as a string: itself, or its to_s (mrb_obj_as_string) */
  MV piece = to_s_string(src);
  buf_put(&b, s->p, (size_t)s->len);
  buf_put(&b, str_of(&piece)->p, (size_t)str_of(&piece)->len);
  out = new_str_value(b.p ? b.p : "", (long)b.n);
  free(b.p);
  *dst = out;
}

void mrbbc_send0(MV *dst, const MV *recv, int m) {
  MV r;
  switch (m) {
    case MRBBC_M_TO_S:
      switch (recv->tag) {
        case MRBBC_STR: r = *recv; break;
        case MRBBC_NIL: r = new_str_value("", 0); break;
        case MRBBC_TRUE: r = new_str_value("true", 4); break;
        case MRBBC_FALSE: r = new_str_value("false", 5); break;
        case MRBBC_SYM: r = new_str_value(sym_of(recv), (long)strlen(sym_of(recv))); break;
        case MRBBC_CLS: r = new_str_value(cls_of(recv)->name, (long)strlen(cls_of(recv)->name)); break;
        case MRBBC_OBJ: {
          /* the program's to_s; the default one prints an address, which is not lowered */
          int id = user_method(recv, "to_s", 0);
          MV out;
          if (id < 0) mrbbc_raise("NotImplementedError", "to_s of an instance is not lowered yet");
          call_user(&out, id, recv, NULL);
          r = out;
          break;
        }
        case MRBBC_INT: {
          char h[32];
          int n = snprintf(h, sizeof h, "%lld", (long long)recv->i);
          r = new_str_value(h, n);
          break;
        }
        default: {  /* Array#to_s is inspect */
          Buf b = {NULL, 0, 0};
          inspect_value(&b, recv);
          r = new_str_value(b.p, (long)b.n);
          free(b.p);
          break;
        }
      }
      break;
    case MRBBC_M_SIZE:
    case MRBBC_M_LENGTH:
      if (recv->tag == MRBBC_STR) r = int_value(str_of(recv)->len);
      else if (recv->tag == MRBBC_ARY) r = int_value(ary_of(recv)->len);
      else if (recv->tag == MRBBC_SYM) r = int_value((int64_t)strlen(sym_of(recv)));
      else if (m == MRBBC_M_SIZE && recv->tag == MRBBC_INT) r = int_value(8);  /* sizeof(mrb_int) */
      else no_method(m == MRBBC_M_SIZE ? "size" : "length", recv);
      break;
    case MRBBC_M_NOT:
      r = bool_value(recv->tag == MRBBC_NIL || recv->tag == MRBBC_FALSE);
      break;
    case MRBBC_M_INSPECT: {
      Buf b = {NULL, 0, 0};
      inspect_value(&b, recv);
      r = new_str_value(b.p ? b.p : "", (long)b.n);
      free(b.p);
      break;
    }
    default: mrbbc_raise("RuntimeError", "unknown method code");
  }
  *dst = r;
}

/* The string of a value as mrb_obj_as_string gives it (an interpolation, a p of a value): a string itself, else its to_s.
 * A to_s that gives no string falls back to mruby's default one, which prints an address: not lowered. */
static MV to_s_string(const MV *v) {
  MV r;
  if (v->tag == MRBBC_STR) return *v;
  mrbbc_send0(&r, v, MRBBC_M_TO_S);
  if (r.tag != MRBBC_STR) mrbbc_raise("NotImplementedError", "to_s of an instance that gives no string is not lowered yet");
  return r;
}
