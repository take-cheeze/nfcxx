#include <ruby.h>

/* nested calls below the depth bound: a call in an argument of a call in an argument of a template converts to three levels
   of nesting under the outer call (rb_obj_is_kind_of(rb_ary_entry(rb_ary_entry(rb_ary_entry(x, i), 0), 1), rb_cString)); the
   two-level form and the nokogiri shape (rb_jump_tag of FIX2INT of rb_ary_entry) convert too */
static VALUE nd_two(VALUE self, VALUE x, VALUE i) {
    return rb_obj_is_kind_of(rb_ary_entry(rb_ary_entry(x, i), 0), rb_cString);
}

static VALUE nd_three(VALUE self, VALUE x, VALUE i) {
    return rb_obj_is_kind_of(rb_ary_entry(rb_ary_entry(rb_ary_entry(x, i), 0), 1), rb_cString);
}

static VALUE nd_jump(VALUE self, VALUE x, VALUE i) {
    rb_jump_tag(FIX2INT(rb_ary_entry(x, i)));
    return Qnil;
}

void Init_nested_depth(void) {
    VALUE m = rb_define_module("NestedDepth");
    rb_define_method(m, "two", nd_two, 2);
    rb_define_method(m, "three", nd_three, 2);
    rb_define_method(m, "jump", nd_jump, 2);
}
