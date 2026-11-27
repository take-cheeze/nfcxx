#include <ruby.h>

/* a call four levels deep is past the depth bound (three levels of nesting under the outer call): the outer call is refused */
static VALUE nf_four(VALUE self, VALUE x, VALUE i) {
    return rb_obj_is_kind_of(rb_ary_entry(rb_ary_entry(rb_ary_entry(rb_ary_entry(x, i), 0), 1), 2), rb_cString);
}

void Init_nested_depth_four(void) {
    VALUE m = rb_define_module("NestedDepthFour");
    rb_define_method(m, "four", nf_four, 2);
}
