#include <ruby.h>

/* nested calls as whole arguments of mapped templates: the inner call is rewritten first and its text is substituted into
   the outer call (kind_of of a call; a class argument that is a nested constant lookup; a funcall in rb_str_concat) */
static VALUE mNA;

static VALUE f(VALUE x) { return x; }

static VALUE na_kind(VALUE self, VALUE x) {
    return rb_obj_is_kind_of(f(x), rb_cString);
}

static VALUE na_concat(VALUE self, VALUE a) {
    return rb_str_concat(a, rb_funcall(a, rb_intern("to_s"), 0));
}

static VALUE na_class(VALUE self) {
    return rb_const_get_at(rb_const_get_at(mNA, rb_intern("A")), rb_intern("B"));
}

void Init_nested_args(void) {
    mNA = rb_define_module("NestedArgs");
    rb_define_method(mNA, "kind", na_kind, 1);
    rb_define_method(mNA, "concat", na_concat, 1);
    rb_define_method(mNA, "klass", na_class, 0);
}
