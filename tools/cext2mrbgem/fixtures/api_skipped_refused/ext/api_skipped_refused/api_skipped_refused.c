#include <ruby.h>

/* Names with no exact mruby equivalent that batch B1 leaves refused (api_map.json): rb_str_subseq (mruby's public
 * substr counts characters, the byte form is internal), rb_gv_get (mruby takes a symbol, not a C name),
 * rb_intern3 (takes an encoding),
 * rb_bug (variadic format), StringValue (takes an lvalue it rewrites). */
static VALUE mApiSkip;

static VALUE api_sub(VALUE self, VALUE s) {
    return rb_str_subseq(s, 0, 1);
}

static const char *iv_name = "@a";

static VALUE api_iv(VALUE self, VALUE o) {
    return rb_iv_get(o, iv_name);
}

static VALUE api_gv(VALUE self) {
    return rb_gv_get("$x");
}

static VALUE api_sym(VALUE self, VALUE s) {
    return rb_sym2str(s);
}

static VALUE api_num(VALUE self) {
    return rb_intern3("12", 2, NULL);
}

static VALUE api_bug(VALUE self) {
    rb_bug("never");
    return Qnil;
}

static VALUE api_sv(VALUE self, VALUE s) {
    StringValue(s);
    return s;
}

void Init_api_skipped_refused(void) {
    mApiSkip = rb_define_module("ApiSkip");
    rb_define_module_function(mApiSkip, "sub", api_sub, 1);
    rb_define_module_function(mApiSkip, "iv", api_iv, 1);
    rb_define_module_function(mApiSkip, "gv", api_gv, 0);
    rb_define_module_function(mApiSkip, "sym", api_sym, 1);
    rb_define_module_function(mApiSkip, "num", api_num, 0);
    rb_define_module_function(mApiSkip, "bug", api_bug, 0);
    rb_define_module_function(mApiSkip, "sv", api_sv, 1);
}
