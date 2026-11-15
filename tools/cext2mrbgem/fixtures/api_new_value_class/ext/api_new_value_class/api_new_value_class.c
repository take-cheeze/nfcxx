#include <ruby.h>
static VALUE mNvc;

/* the class is a VALUE parameter: mrb_class_ptr unwraps it, and argc and argv are a literal and NULL */
static VALUE nvc_make(VALUE self, VALUE klass) {
    return rb_class_new_instance(0, NULL, klass);
}

/* a CRuby class constant maps to the mruby class expression; argv is a local VALUE array */
static VALUE nvc_range(VALUE self, VALUE n) {
    VALUE argv[3];
    argv[0] = n;
    argv[1] = n;
    argv[2] = n;
    return rb_class_new_instance(3, argv, rb_cRange);
}

void Init_api_new_value_class(void) {
    mNvc = rb_define_module("NewValueClass");
    rb_define_module_function(mNvc, "make", nvc_make, 1);
    rb_define_module_function(mNvc, "range", nvc_range, 1);
}
