#include <ruby.h>
static VALUE mVl;

/* the value of rb_ivar_set is used: mruby's mrb_iv_set returns void, so this stays refused */
static VALUE vl_store(VALUE self, VALUE h, VALUE k) {
    VALUE v = rb_ivar_set(h, k, Qnil);
    return v;
}

void Init_api_value_lost(void) {
    mVl = rb_define_module("ValueLost");
    rb_define_module_function(mVl, "store", vl_store, 2);
}
