#include <ruby.h>
#include "tiny.h"

/* A comment mentioning rb_ensure must not be treated as a call. */
static VALUE mTiny;
static VALUE cGreeter;

static VALUE tiny_hello(VALUE self) {
    return rb_str_new_cstr("hello");
}

static VALUE tiny_echo(VALUE self, VALUE str) {
    return rb_str_new(RSTRING_PTR(str), RSTRING_LEN(str));
}

static VALUE tiny_truthy(VALUE self, VALUE v) {
    if (RTEST(v)) return Qtrue;
    return Qfalse;
}

static VALUE tiny_add(VALUE self, VALUE a, VALUE b) {
    long x = NUM2LONG(a);
    long y = NUM2LONG(b);
    return LONG2NUM(x + y);
}

static VALUE tiny_fail(VALUE self) {
    rb_raise(rb_eArgError, "bad input: %d", 3);
    return Qnil;
}

static VALUE tiny_version(VALUE self) {
    return rb_str_new_cstr("0.1");
}

static VALUE tiny_helper_str(VALUE self);

static VALUE tiny_greeting(VALUE self) {
    return tiny_helper_str(self);
}

static VALUE tiny_helper_str(VALUE self) {
    return rb_str_new_cstr("hi");
}

void Init_tiny(void) {
    mTiny = rb_define_module("Tiny");
    cGreeter = rb_define_class_under(mTiny, "Greeter", rb_cObject);
    rb_define_method(mTiny, "hello", tiny_hello, 0);
    rb_define_method(mTiny, "hello2", (VALUE (*)(ANYARGS))tiny_hello, 0);
    rb_define_method(mTiny, "echo", tiny_echo, 1);
    rb_define_method(mTiny, "truthy", tiny_truthy, 1);
    rb_define_method(mTiny, "add", tiny_add, 2);
    rb_define_method(mTiny, "fail", tiny_fail, 0);
    rb_define_method(mTiny, "greeting", tiny_greeting, 0);
    rb_define_singleton_method(mTiny, "version", tiny_version, 0);
}
