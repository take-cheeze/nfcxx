#include <ruby.h>
static VALUE mIl;
static ID id_lazy = 0;   /* unset, then set from one literal wherever it is used: a call may name the literal */

static VALUE il_send(VALUE self, VALUE obj) {
    if (0 == id_lazy) {
        id_lazy = rb_intern("lazy");
    }
    return rb_funcall(obj, id_lazy, 0);
}

void Init_api_id_lazy(void) {
    mIl = rb_define_module("IdLazy");
    rb_define_module_function(mIl, "send", il_send, 1);
}
