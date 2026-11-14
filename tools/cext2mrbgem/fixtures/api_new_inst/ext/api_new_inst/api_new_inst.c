#include <ruby.h>

/* rb_class_new_instance(argc, argv, klass) (api_map.json batch N1): mrb_obj_new(mrb, klass, argc, argv) */
static VALUE cApiNew;

static VALUE api_make(VALUE self, VALUE arg) {
    int argc = 1;
    VALUE argv[1];
    argv[0] = arg;
    return rb_class_new_instance(argc, argv, cApiNew);
}

void Init_api_new_inst(void) {
    cApiNew = rb_define_class("ApiNew", rb_cObject);
    rb_define_module_function(cApiNew, "make", api_make, 1);
}
