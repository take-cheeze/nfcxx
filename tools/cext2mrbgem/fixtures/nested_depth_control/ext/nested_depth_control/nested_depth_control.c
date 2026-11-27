#include <ruby.h>

/* control: a nested call whose innermost call is a refused API stays refused, at every depth */
static VALUE nc_refused(VALUE self, VALUE x, VALUE i) {
    return rb_obj_is_kind_of(rb_ary_entry(rb_ary_entry(x, rb_reg_regcomp(i)), 0), rb_cString);
}

void Init_nested_depth_control(void) {
    VALUE m = rb_define_module("NestedDepthControl");
    rb_define_method(m, "refused", nc_refused, 2);
}
