/* Prototype (opt-in, --cruby-fallback): the mruby side of the fallback. It converts mruby values to nfcx_val, calls the
 * embedded CRuby (nfcx_cruby_vm.c), and converts the result back. A CRuby error raises RuntimeError in mruby. */
#include <string.h>
#include <mruby.h>
#include <mruby/string.h>
#include <mruby/error.h>
#include "nfcx_cruby_vm.h"

#define NFCX_CRUBY_ERR_CAP 512
#define NFCX_CRUBY_RET_CAP 4096

static int to_nfcx(mrb_state *mrb, mrb_value v, nfcx_val *out) {
  switch (mrb_type(v)) {
    case MRB_TT_FALSE:
      out->tag = mrb_nil_p(v) ? NFCX_NIL : NFCX_FALSE;
      return 0;
    case MRB_TT_TRUE: out->tag = NFCX_TRUE; return 0;
    case MRB_TT_INTEGER: out->tag = NFCX_INT; out->i = (long long)mrb_fixnum(v); return 0;
    case MRB_TT_FLOAT: out->tag = NFCX_FLOAT; out->f = mrb_float(v); return 0;
    case MRB_TT_STRING: out->tag = NFCX_STR; out->s = RSTRING_PTR(v); out->len = (size_t)RSTRING_LEN(v); return 0;
    case MRB_TT_SYMBOL: {
      mrb_int n = 0;
      const char *s = mrb_sym_name_len(mrb, mrb_symbol(v), &n);
      out->tag = NFCX_SYM; out->s = s; out->len = (size_t)n;
      return 0;
    }
    default: return 1;
  }
}

static mrb_value from_nfcx(mrb_state *mrb, const nfcx_val *v) {
  switch (v->tag) {
    case NFCX_NIL: return mrb_nil_value();
    case NFCX_TRUE: return mrb_true_value();
    case NFCX_FALSE: return mrb_false_value();
    case NFCX_INT: return mrb_fixnum_value((mrb_int)v->i);
    case NFCX_FLOAT: return mrb_float_value(mrb, v->f);
    case NFCX_STR: return mrb_str_new(mrb, v->s, (mrb_int)v->len);
    case NFCX_SYM: return mrb_symbol_value(mrb_intern(mrb, v->s, (mrb_int)v->len));
  }
  return mrb_nil_value();
}

/* Calls recv_path.meth(*argv) in the embedded CRuby. Returns the result as an mruby value, or raises RuntimeError with the
 * CRuby exception's class and message. */
mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv) {
  nfcx_val in[16];
  if (argc < 0 || argc > 16) mrb_raise(mrb, E_ARGUMENT_ERROR, "CRuby fallback: too many arguments for the prototype");
  for (mrb_int i = 0; i < argc; i++) {
    if (to_nfcx(mrb, argv[i], &in[i])) mrb_raise(mrb, E_TYPE_ERROR, "CRuby fallback: argument type not supported by the prototype");
  }
  nfcx_val ret;
  char buf[NFCX_CRUBY_RET_CAP];
  char err[NFCX_CRUBY_ERR_CAP] = "";
  if (nfcx_cruby_call(recv_path, meth, (int)argc, in, &ret, buf, sizeof buf, err, sizeof err))
    mrb_raise(mrb, E_RUNTIME_ERROR, err[0] ? err : "CRuby fallback: call failed");
  return from_nfcx(mrb, &ret);
}
