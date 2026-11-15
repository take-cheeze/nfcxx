#include <ruby.h>
static VALUE mIdg;
static ID id_hello;     /* written once, from rb_intern of a literal: a call may name it */
static ID id_twice;     /* written twice: the converter must refuse a call that passes it */

static VALUE idg_send(VALUE self, VALUE obj, VALUE arg) {
    rb_funcall(obj, id_hello, 1, arg);
    rb_funcall(obj, id_twice, 1, arg);
    return Qnil;
}

void Init_api_id_global(void) {
    mIdg = rb_define_module("IdGlobal");
    id_hello = rb_intern("hello");
    id_twice = rb_intern("first");
    id_twice = rb_intern("second");
    rb_define_module_function(mIdg, "send", idg_send, 2);
}
