#include <ruby.h>

/* Registered methods that are also called directly from another C function. The converter splits each one: the
   body becomes <name>_impl (direct calls), and the registration keeps <name> for a wrapper with the mruby signature.
   reg_split_twice makes a String, so its impl takes the mruby state; reg_split_plain does not; reg_split_var is
   variadic (argc -1), and its impl takes (argc, argv, self). */
static VALUE mRegSplit;

static VALUE reg_split_twice(VALUE self, VALUE x) {
    return rb_str_new_cstr("twice");
}

static VALUE reg_split_plain(VALUE self, VALUE x) {
    return x;
}

static VALUE reg_split_var(int argc, VALUE *argv, VALUE self) {
    return INT2FIX(argc);
}

static VALUE reg_split_outer(VALUE self) {
    VALUE a = reg_split_twice(self, self);
    VALUE b = reg_split_plain(self, a);
    VALUE c = reg_split_var(0, NULL, self);
    return rb_ary_new_capa(3);
}

void Init_reg_split(void) {
    mRegSplit = rb_define_module("RegSplit");
    rb_define_method(mRegSplit, "twice", reg_split_twice, 1);
    rb_define_method(mRegSplit, "plain", reg_split_plain, 1);
    rb_define_method(mRegSplit, "var", reg_split_var, -1);
    rb_define_method(mRegSplit, "outer", reg_split_outer, 0);
}
