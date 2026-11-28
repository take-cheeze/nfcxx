/* mruby.h over the mrbbc runtime (mrbrt): the names mruby's C API uses, for C++ written against mruby (the fork's
 * mruby-marshal). An mrb_value is an MV; the mrb_state is the runtime's (one per process). Only the subset that a converted
 * gem uses is here: each name is added when a file that includes this header needs it. */
#ifndef NFCX_MRUBY_COMPAT_H
#define NFCX_MRUBY_COMPAT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "../mrbrt.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t mrb_int;
typedef long mrb_sym;
typedef MV mrb_value;
typedef struct mrb_state { int unused; } mrb_state;
typedef struct RClass RClass;

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
#endif

#endif
