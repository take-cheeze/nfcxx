#include <ruby.h>
static VALUE mStoreRefused;
static VALUE (*sr_saved)(VALUE);
static VALUE sr_c(VALUE v) { return rb_str_new_cstr("x"); }
static VALUE sr_keep(VALUE v, VALUE (*c)(VALUE)) { sr_saved = c; return v; }
static VALUE sr_run(VALUE self, VALUE v) { return sr_keep(v, sr_c); }
void Init_api_store_callback_refused(void) {
    mStoreRefused = rb_define_module("StoreRefused");
    rb_define_module_function(mStoreRefused, "run", sr_run, 1);
}
