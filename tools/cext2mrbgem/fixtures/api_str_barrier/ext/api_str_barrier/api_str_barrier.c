#include <ruby.h>
static VALUE mStrBarrier;
static VALUE cBox;
static VALUE m2_cat(VALUE self, VALUE s) {
    rb_str_cat2(s, "!");
    rb_str_cat_cstr(s, "?");
    return s;
}
static VALUE m2_set(VALUE self, VALUE obj, VALUE v) {
    VALUE slot = Qnil;
    RB_OBJ_WRITTEN(obj, slot, v);
    return slot;
}
void Init_api_str_barrier(void) {
    mStrBarrier = rb_define_module("StrBarrier");
    cBox = rb_define_class_under(mStrBarrier, "Box", rb_cObject);
    rb_undef_alloc_func(cBox);
    rb_define_module_function(mStrBarrier, "cat", m2_cat, 1);
    rb_define_module_function(mStrBarrier, "set", m2_set, 2);
}
