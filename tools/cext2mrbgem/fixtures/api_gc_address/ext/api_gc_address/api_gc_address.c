#include <ruby.h>
static VALUE g_keep;
static VALUE mGcAddr;
static VALUE gca_keep(VALUE self, VALUE v) {
    g_keep = v;
    return g_keep;
}
void Init_api_gc_address(void) {
    mGcAddr = rb_define_module("GcAddr");
    rb_gc_register_address(&g_keep);
    rb_global_variable(&g_keep);
    rb_define_module_function(mGcAddr, "keep", gca_keep, 1);
}
