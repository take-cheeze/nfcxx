#include <ruby.h>

/* rb_path2class (a C string path) and rb_path_to_class (a String VALUE): a class looked up by its "::" path, in a
 * registered method and at Init. Foo is a module, Foo::Bar a class: both kinds of segment are walked. */
static VALUE p2c_bar;

static VALUE p2c_lookup(VALUE self) {
    return rb_path2class("Foo::Bar");
}

static VALUE p2c_by_string(VALUE self, VALUE path) {
    return rb_path_to_class(path);
}

void Init_path2class(void) {
    VALUE mFoo = rb_define_module("Foo");
    rb_define_class_under(mFoo, "Bar", rb_cObject);
    p2c_bar = rb_path2class("Foo::Bar");
    rb_define_module_function(mFoo, "lookup", p2c_lookup, 0);
    rb_define_module_function(mFoo, "by_string", p2c_by_string, 1);
}
