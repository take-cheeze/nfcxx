/* Prototype (opt-in, --cruby-fallback): the CRuby side of the fallback. Only this file includes ruby.h, so its names do not
 * meet the mruby ones in the glue file. */
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdio.h>
#include <string.h>
#include "nfcx_cruby_vm.h"

static int booted = 0;

static void put_msg(char *err, size_t errlen, const char *msg) {
  if (err && errlen) snprintf(err, errlen, "%s", msg);
}

/* fills err from the pending exception (class and message) and clears it */
static void put_pending(char *err, size_t errlen, int st) {
  VALUE exc = rb_errinfo();
  rb_set_errinfo(Qnil);
  if (NIL_P(exc)) {
    char b[64];
    snprintf(b, sizeof b, "CRuby error (state %d)", st);
    put_msg(err, errlen, b);
    return;
  }
  VALUE cls = rb_class_name(CLASS_OF(exc));
  VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
  char b[400];
  snprintf(b, sizeof b, "%s: %s", RSTRING_PTR(cls), StringValueCStr(msg));
  put_msg(err, errlen, b);
}

static VALUE require_path(VALUE path) { return rb_require_string(path); }

int nfcx_cruby_boot(const char *so_path, char *err, size_t errlen) {
  if (booted) return 0;
  int argc = 1;
  char *argv_storage[] = {(char *)"nfcx", NULL};
  char **argv = argv_storage;
  ruby_sysinit(&argc, &argv);
  RUBY_INIT_STACK;
  ruby_init();
  int st = 0;
  rb_protect(require_path, rb_str_new_cstr(so_path), &st);
  if (st) {
    put_pending(err, errlen, st);
    return 1;
  }
  booted = 1;
  return 0;
}

/* nfcx_val -> VALUE; a symbol is interned, a string is copied */
static int to_value(const nfcx_val *v, VALUE *out) {
  switch (v->tag) {
    case NFCX_NIL: *out = Qnil; return 0;
    case NFCX_TRUE: *out = Qtrue; return 0;
    case NFCX_FALSE: *out = Qfalse; return 0;
    case NFCX_INT: *out = LL2NUM(v->i); return 0;
    case NFCX_FLOAT: *out = DBL2NUM(v->f); return 0;
    case NFCX_STR: *out = rb_enc_str_new(v->s, (long)v->len, rb_utf8_encoding()); return 0;
    case NFCX_SYM: *out = ID2SYM(rb_intern3(v->s, (long)v->len, rb_utf8_encoding())); return 0;
  }
  return 1;
}

/* VALUE -> nfcx_val; a string is copied into ret_buf */
static int from_value(VALUE v, nfcx_val *out, char *buf, size_t cap, size_t *used) {
  if (NIL_P(v)) { out->tag = NFCX_NIL; return 0; }
  if (v == Qtrue) { out->tag = NFCX_TRUE; return 0; }
  if (v == Qfalse) { out->tag = NFCX_FALSE; return 0; }
  if (FIXNUM_P(v) || RB_TYPE_P(v, T_BIGNUM)) {
    out->tag = NFCX_INT;
    out->i = NUM2LL(v);
    return 0;
  }
  if (RB_TYPE_P(v, T_FLOAT)) { out->tag = NFCX_FLOAT; out->f = RFLOAT_VALUE(v); return 0; }
  if (RB_TYPE_P(v, T_STRING) || SYMBOL_P(v)) {
    VALUE s = SYMBOL_P(v) ? rb_sym2str(v) : v;
    long n = RSTRING_LEN(s);
    if (n < 0 || (size_t)n > cap - *used) return 1;
    memcpy(buf + *used, RSTRING_PTR(s), (size_t)n);
    out->tag = SYMBOL_P(v) ? NFCX_SYM : NFCX_STR;
    out->s = buf + *used;
    out->len = (size_t)n;
    *used += (size_t)n;
    return 0;
  }
  return 1;
}

typedef struct { VALUE recv; ID meth; int argc; VALUE *argv; } call_args;

static VALUE do_call(VALUE a) {
  call_args *c = (call_args *)a;
  return rb_funcallv(c->recv, c->meth, c->argc, c->argv);
}

static VALUE resolve_path(VALUE path) { return rb_path_to_class(path); }

int nfcx_cruby_call(const char *recv_path, const char *meth, int argc, const nfcx_val *argv,
                    nfcx_val *ret, char *ret_buf, size_t ret_cap, char *err, size_t errlen) {
  if (!booted) { put_msg(err, errlen, "CRuby VM not booted"); return 1; }
  int st = 0;
  VALUE recv = rb_protect(resolve_path, rb_str_new_cstr(recv_path), &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  VALUE *vals = NULL;
  if (argc > 0) {
    vals = ALLOCA_N(VALUE, (size_t)argc);
    for (int i = 0; i < argc; i++) {
      if (to_value(&argv[i], &vals[i])) { put_msg(err, errlen, "argument type not supported by the prototype"); return 1; }
    }
  }
  call_args c = {recv, rb_intern(meth), argc, vals};
  VALUE result = rb_protect(do_call, (VALUE)&c, &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  size_t used = 0;
  if (from_value(result, ret, ret_buf, ret_cap, &used)) {
    put_msg(err, errlen, "result type not supported by the prototype");
    return 1;
  }
  return 0;
}
