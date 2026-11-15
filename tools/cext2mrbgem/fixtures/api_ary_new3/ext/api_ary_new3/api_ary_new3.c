#include <ruby.h>
static VALUE mAryNew3;
static VALUE an3_run(VALUE self, VALUE x, VALUE y) {
    VALUE a = rb_ary_new3(2, x, y);
    VALUE b = rb_ary_new3(0);
    (void)b;
    return a;
}
void Init_api_ary_new3(void) {
    mAryNew3 = rb_define_module("AryNew3");
    rb_define_module_function(mAryNew3, "run", an3_run, 2);
}
