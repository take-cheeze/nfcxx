#include <ruby.h>

/* A macro defined here is local, but its body uses a CRuby API with no entry: the API is still refused. */
#define LNR_CALL rb_reg_nth_match(0, self)

/* Only used, never defined in the input: not local, refused. */
static VALUE lnr_missing(VALUE self) {
    return rb_ln_missing(self);
}

/* A fallback under a conditional that does not name it: the CRuby name may be the real one, so it is refused. */
#if !defined(HAVE_RB_LN_FALLBACK)
#define rb_ln_fallback(v) (v)
#endif

static VALUE lnr_fallback(VALUE self) {
    return rb_ln_fallback(self);
}

static VALUE lnr_call(VALUE self) {
    return LNR_CALL;
}

/* A prototype is not a definition: a CRuby-style name declared here and never defined is still refused. */
VALUE rb_lnr_proto(VALUE self);

static VALUE lnr_proto(VALUE self) {
    return rb_lnr_proto(self);
}

void Init_local_names_refused(void) {
    VALUE mLNR = rb_define_module("LocalNamesRefused");
    rb_define_method(mLNR, "missing", lnr_missing, 0);
    rb_define_method(mLNR, "fallback", lnr_fallback, 0);
    rb_define_method(mLNR, "call", lnr_call, 0);
    rb_define_method(mLNR, "proto", lnr_proto, 0);
}
