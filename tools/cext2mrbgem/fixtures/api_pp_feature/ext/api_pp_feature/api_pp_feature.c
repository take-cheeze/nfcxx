#include <ruby.h>
static VALUE mPf;

/* a feature test inside a function body: mruby defines none of CRuby's feature macros, so the #ifdef branch is not taken */
static VALUE pf_len(VALUE self, VALUE st) {
#ifdef RSTRUCT_LEN
    return LONG2NUM(RSTRUCT_LEN(st));
#else
    return Qnil;
#endif
}

void Init_api_pp_feature(void) {
    mPf = rb_define_module("PpFeature");
    rb_define_module_function(mPf, "len", pf_len, 1);
}
