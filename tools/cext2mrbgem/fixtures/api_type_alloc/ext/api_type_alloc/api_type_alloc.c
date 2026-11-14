#include <ruby.h>

/* TYPE(x) is rb_type (mrb_type: compare with MRB_TT_*); T_STRING is an exact type test; rb_obj_alloc allocates a plain
 * object of a class (mrb_obj_alloc with MRB_TT_OBJECT; the class VALUE is converted with mrb_class_ptr) */
static VALUE mTA;

static VALUE ta_is_string(VALUE self, VALUE v) {
    return TYPE(v) == T_STRING ? Qtrue : Qfalse;
}

static VALUE ta_new(VALUE self, VALUE klass) {
    return rb_obj_alloc(klass);
}

void Init_api_type_alloc(void) {
    mTA = rb_define_module("TypeAlloc");
    rb_define_module_function(mTA, "string?", ta_is_string, 1);
    rb_define_module_function(mTA, "new", ta_new, 1);
}
