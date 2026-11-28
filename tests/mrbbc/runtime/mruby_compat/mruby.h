/* mruby.h over the mrbbc runtime (mrbrt): the names mruby's C API uses, for C++ written against mruby (the fork's
 * mruby-marshal). An mrb_value is an MV; the mrb_state is the runtime's (one per process). Only the subset that a converted
 * gem uses is here: each name is added when a file that includes this header needs it. */
#ifndef NFCX_MRUBY_COMPAT_H
#define NFCX_MRUBY_COMPAT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include "../mrbrt.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t mrb_int;
typedef long mrb_sym;
typedef MV mrb_value;
/* A class, module or object: the value (an MV, nil until it is looked up) and, for a class, its name. The builtin classes
 * (String, Array, ...) have no program value: their RClass has a nil value and only a name. */
struct RClass {
  MV v;
  const char *name;
  int builtin;
  struct RClass *next;
};
typedef struct RClass RClass;
/* an object's common header: its value. RObject is the object mrb_obj_alloc makes. */
typedef struct RBasic { MV v; } RBasic;
typedef struct RObject { MV v; } RObject;

/* the interpreter state: one per process (mrbrt is a single runtime). The builtin classes are RClass values with no program
 * value; they are set up by nfcx_state_init. */
typedef struct mrb_state {
  RClass *object_class, *string_class, *array_class, *hash_class, *integer_class, *symbol_class,
         *nil_class, *true_class, *false_class;
} mrb_state;

/* the value tags of mrbrt, under mruby's names where they differ */

enum mrb_vtype {
  MRB_TT_FALSE = 0, MRB_TT_TRUE, MRB_TT_SYMBOL, MRB_TT_INTEGER, MRB_TT_STRING, MRB_TT_ARRAY,
  MRB_TT_HASH, MRB_TT_OBJECT, MRB_TT_CLASS, MRB_TT_MODULE, MRB_TT_PROC, MRB_TT_DATA, MRB_TT_FLOAT
};

/* ---- values (nil, booleans, integers, symbols, strings, arrays, hashes) ---- */
static inline mrb_value mrb_nil_value(void) { mrb_value v; mrbbc_set_nil(&v); return v; }
static inline mrb_value mrb_true_value(void) { mrb_value v; mrbbc_set_bool(&v, 1); return v; }
static inline mrb_value mrb_false_value(void) { mrb_value v; mrbbc_set_bool(&v, 0); return v; }
static inline int mrb_nil_p(mrb_value v) { return mrbbc_tag(&v) == MRBBC_NIL; }
static inline int mrb_test(mrb_value v) { int t = mrbbc_tag(&v); return t != MRBBC_NIL && t != MRBBC_FALSE; }
static inline mrb_value mrb_fixnum_value(mrb_int i) { mrb_value v; mrbbc_int_new(&v, (long long)i); return v; }
static inline mrb_int mrb_fixnum(mrb_value v) { int64_t i = 0; mrbbc_int_read(&v, &i); return (mrb_int)i; }
static inline mrb_value mrb_symbol_value(mrb_sym s) { mrb_value v; mrbbc_sym_from_index(&v, (long)s); return v; }
static inline mrb_sym mrb_symbol(mrb_value v) { return (mrb_sym)mrbbc_sym_index(&v); }
static inline int mrb_symbol_p(mrb_value v) { return mrbbc_tag(&v) == MRBBC_SYM; }
static inline const char *mrb_sym2name_len(mrb_state *mrb, mrb_sym s, mrb_int *len) {
  const char *n = mrbbc_sym_name((long)s);
  (void)mrb;
  if (len) *len = (mrb_int)strlen(n);
  return n;
}
static inline mrb_sym mrb_intern_cstr(mrb_state *mrb, const char *name) { mrb_value v; (void)mrb; mrbbc_sym(&v, name); return (mrb_sym)mrbbc_sym_index(&v); }
#define mrb_intern_lit(mrb, lit) mrb_intern_cstr((mrb), (lit))

/* the mruby type tag of a value: nil and false are MRB_TT_FALSE, true MRB_TT_TRUE */
static inline int mrb_type(mrb_value v) {
  switch (mrbbc_tag(&v)) {
    case MRBBC_NIL: case MRBBC_FALSE: return MRB_TT_FALSE;
    case MRBBC_TRUE: return MRB_TT_TRUE;
    case MRBBC_INT: return MRB_TT_INTEGER;
    case MRBBC_STR: return MRB_TT_STRING;
    case MRBBC_ARY: return MRB_TT_ARRAY;
    case MRBBC_SYM: return MRB_TT_SYMBOL;
    case MRBBC_HASH: return MRB_TT_HASH;
    case MRBBC_OBJ: return MRB_TT_OBJECT;
    case MRBBC_CLS: return MRB_TT_CLASS;
    default: return MRB_TT_DATA;
  }
}

static inline mrb_value mrb_str_new(mrb_state *mrb, const char *p, mrb_int n) { mrb_value v; (void)mrb; mrbbc_str_new(&v, p, (long)n); return v; }
static inline const char *nfcx_rstring_ptr(mrb_value v) { const char *p = NULL; long n = 0; mrbbc_str_view(&v, &p, &n); return p; }
static inline mrb_int nfcx_rstring_len(mrb_value v) { const char *p = NULL; long n = 0; mrbbc_str_view(&v, &p, &n); return (mrb_int)n; }
#define RSTRING_PTR(v) nfcx_rstring_ptr(v)
#define RSTRING_LEN(v) nfcx_rstring_len(v)

static inline mrb_value mrb_ary_new_capa(mrb_state *mrb, mrb_int capa) { mrb_value v; (void)mrb; mrbbc_ary_new(&v, (long)capa); return v; }
static inline mrb_value mrb_ary_new(mrb_state *mrb) { return mrb_ary_new_capa(mrb, 4); }
static inline void mrb_ary_push(mrb_state *mrb, mrb_value ary, mrb_value v) { (void)mrb; mrbbc_ary_push(&ary, &v); }
static inline mrb_value mrb_ary_ref(mrb_state *mrb, mrb_value ary, mrb_int i) { mrb_value v; (void)mrb; mrbbc_ary_elt(&v, &ary, (long)i); return v; }
static inline mrb_int nfcx_ary_len(mrb_value ary) { return (mrb_int)mrbbc_ary_len(&ary); }
static inline const mrb_value *nfcx_ary_ptr(mrb_value ary) { const MV *items = NULL; long n = 0; mrbbc_ary_items(&ary, &items, &n); return items; }
#define RARRAY_LEN(v) nfcx_ary_len(v)
#define RARRAY_PTR(v) ((mrb_value *)nfcx_ary_ptr(v))

static inline mrb_value mrb_hash_new(mrb_state *mrb) { mrb_value v; (void)mrb; mrbbc_hash_new(&v, 4); return v; }
static inline void mrb_hash_set(mrb_state *mrb, mrb_value h, mrb_value k, mrb_value v) { (void)mrb; mrbbc_hash_set(&h, &k, &v); }

#ifdef __cplusplus
}

/* ---- classes, state, instance variables, calls and errors (milestone 1: program classes and objects) ---- */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

/* the registry of RClass values, by name (one per name; a class's value is looked up when it is first needed) */
static RClass *nfcx_classes = NULL;

static inline RClass *nfcx_class_named(const char *name, int builtin) {
  RClass *c;
  size_t n = strlen(name);
  for (c = nfcx_classes; c != NULL; c = c->next) if (strcmp(c->name, name) == 0) return c;
  c = (RClass *)calloc(1, sizeof *c);
  c->name = (const char *)malloc(n + 1);
  memcpy((void *)c->name, name, n + 1);
  c->builtin = builtin;
  c->v = mrb_nil_value();
  c->next = nfcx_classes;
  nfcx_classes = c;
  return c;
}

/* the RClass of a program class value (named by its own name, which mrbrt keeps) */
static inline RClass *nfcx_class_of_value(MV v) {
  const char *name = mrbbc_class_name(&v);
  RClass *c = nfcx_class_named(name, 0);
  c->v = v;
  return c;
}

/* the interpreter state. Builtin classes are RClass values with no program value. */
static inline void nfcx_state_init(mrb_state *M) {
  M->object_class = nfcx_class_named("Object", 1);
  M->string_class = nfcx_class_named("String", 1);
  M->array_class = nfcx_class_named("Array", 1);
  M->hash_class = nfcx_class_named("Hash", 1);
  M->integer_class = nfcx_class_named("Integer", 1);
  M->symbol_class = nfcx_class_named("Symbol", 1);
  M->nil_class = nfcx_class_named("NilClass", 1);
  M->true_class = nfcx_class_named("TrueClass", 1);
  M->false_class = nfcx_class_named("FalseClass", 1);
}

/* the value of a class: a program class is looked up once (a missing one raises NameError, as mrbbc_getconst does) */
static inline mrb_value mrb_obj_value(RClass *c) {
  if (mrbbc_tag(&c->v) == MRBBC_NIL && !c->builtin) mrbbc_getconst(&c->v, c->name);
  return c->v;
}
static inline mrb_value mrb_obj_value(RBasic *o) { return o->v; }
static inline mrb_value mrb_obj_value(RObject *o) { return o->v; }

/* a class by name: its RClass (the value is looked up when it is used) */
static inline RClass *mrb_class_get(mrb_state *M, const char *name) { (void)M; return nfcx_class_named(name, 0); }
static inline RClass *mrb_class_get(mrb_state *M, const char *name, int) { return mrb_class_get(M, name); }

/* the class of a value: a program object's class, or the builtin class of a core value */
static inline RClass *mrb_class(mrb_state *M, mrb_value v) {
  mrb_value c;
  switch (mrb_type(v)) {
    case MRB_TT_STRING: return M->string_class;
    case MRB_TT_ARRAY: return M->array_class;
    case MRB_TT_HASH: return M->hash_class;
    case MRB_TT_INTEGER: return M->integer_class;
    case MRB_TT_SYMBOL: return M->symbol_class;
    case MRB_TT_TRUE: return M->true_class;
    case MRB_TT_FALSE: return mrb_nil_p(v) ? M->nil_class : M->false_class;
    default: break;
  }
  mrbbc_obj_class(&c, &v);
  if (mrb_nil_p(c)) return M->object_class;
  return nfcx_class_of_value(c);
}
static inline RClass *mrb_obj_class(mrb_state *M, mrb_value v) { return mrb_class(M, v); }
static inline RClass *mrb_class_real(RClass *c) { return c; }

/* instance variables: an object's ivars by symbol */
static inline mrb_value mrb_iv_get(mrb_state *M, mrb_value obj, mrb_sym sym) {
  mrb_value out;
  (void)M;
  mrbbc_getiv(&out, &obj, mrbbc_sym_name((long)sym));
  return out;
}
static inline void mrb_iv_set(mrb_state *M, mrb_value obj, mrb_sym sym, mrb_value v) {
  (void)M;
  mrbbc_setiv(&obj, mrbbc_sym_name((long)sym), &v);
}

/* an object of class c (the type is mruby's MRB_TT_OBJECT) */
static inline RObject *mrb_obj_alloc(mrb_state *M, int type, RClass *c) {
  RObject *o = (RObject *)calloc(1, sizeof *o);
  mrb_value cls = mrb_obj_value(c);
  (void)M; (void)type;
  mrbbc_alloc(&o->v, &cls);
  return o;
}

/* calls: a program method of a program object is run through the runtime's dispatch (mrbbc_find_send gives its number,
 * mrbbc_user_call runs it). A method the program does not define is NoMethodError for now: builtin dispatch is milestone 2. */
static inline mrb_value mrb_funcall_argv(mrb_state *M, mrb_value recv, mrb_sym sym, mrb_int argc, const mrb_value *argv) {
  const char *name = mrbbc_sym_name((long)sym);
  mrb_value ret;
  mrb_value *vec = (mrb_value *)malloc(sizeof(mrb_value) * (size_t)(argc + 1));
  int id;
  (void)M;
  vec[0] = recv;
  for (mrb_int i = 0; i < argc; i++) vec[i + 1] = argv[i];
  id = mrbbc_find_send(&recv, name, (long)argc, 0);
  if (id < 0) {
    free(vec);
    mrbbc_no_method(&recv, name);
  }
  {
    MV blk = mrb_nil_value();  /* no block: the runtime passes a nil block, as call_user does */
    mrbbc_user_call(id, &ret, vec, &blk, (long)argc);
  }
  free(vec);
  return ret;
}
static inline mrb_value mrb_funcall(mrb_state *M, mrb_value recv, const char *name, mrb_int argc, ...) {
  mrb_value args[16];
  va_list ap;
  mrb_int i;
  if (argc > 16) mrbbc_raise("ArgumentError", "too many arguments for the compatibility layer");
  va_start(ap, argc);
  for (i = 0; i < argc; i++) args[i] = va_arg(ap, mrb_value);
  va_end(ap);
  return mrb_funcall_argv(M, recv, mrb_intern_cstr(M, name), argc, args);
}

/* errors: the class is named, so the runtime raises it by that name (mrbbc_raise) */
static inline void mrb_raise(mrb_state *M, RClass *c, const char *msg) { (void)M; mrbbc_raise(c->name, msg); }
static inline void nfcx_raisef_impl(mrb_state *M, RClass *c, const char *fmt, va_list ap) {
  char buf[512];
  size_t k = 0;
  (void)M;
  for (const char *f = fmt; *f && k < sizeof buf - 1; f++) {
    if (*f != '%') { buf[k++] = *f; continue; }
    f++;
    if (*f == 'S') {
      mrb_value v = va_arg(ap, mrb_value);
      char tmp[64];
      const char *t = "?";
      if (mrb_type(v) == MRB_TT_STRING) t = RSTRING_PTR(v);
      else if (mrb_type(v) == MRB_TT_INTEGER) { snprintf(tmp, sizeof tmp, "%lld", (long long)mrb_fixnum(v)); t = tmp; }
      else if (mrb_type(v) == MRB_TT_SYMBOL) t = mrbbc_sym_name((long)mrb_symbol(v));
      while (*t && k < sizeof buf - 1) buf[k++] = *t++;
    } else if (*f == 's') {
      const char *t = va_arg(ap, const char *);
      while (*t && k < sizeof buf - 1) buf[k++] = *t++;
    } else if (*f == 'd') {
      k += (size_t)snprintf(buf + k, sizeof buf - k, "%d", va_arg(ap, int));
    } else if (*f == 'l' && f[1] == 'd') {
      f++;
      k += (size_t)snprintf(buf + k, sizeof buf - k, "%ld", va_arg(ap, long));
    } else if (*f == '%') {
      buf[k++] = '%';
    }
  }
  buf[k] = 0;
  mrbbc_raise(c->name, buf);
}
static inline void mrb_raisef(mrb_state *M, RClass *c, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  nfcx_raisef_impl(M, c, fmt, ap);
  va_end(ap);
}

/* GC arena and assertions: the runtime's collector is precise on its own frames, so the arena is a no-op here */
static inline int mrb_gc_arena_save(mrb_state *M) { (void)M; return 0; }
static inline void mrb_gc_arena_restore(mrb_state *M, int idx) { (void)M; (void)idx; }
#define mrb_assert(x) ((void)0)

/* identity */
static inline int mrb_obj_equal(mrb_state *M, mrb_value a, mrb_value b) { (void)M; return memcmp(&a, &b, sizeof a) == 0; }
static inline int mrb_obj_eq(mrb_state *M, mrb_value a, mrb_value b) { return mrb_obj_equal(M, a, b); }
static inline mrb_int mrb_obj_id(mrb_value v) { return (mrb_int)(intptr_t)mrbbc_obj_identity(&v); }

#endif

#endif
