#include <ruby.h>
#define f_add(x,y) rb_funcall(x, '+', 1, y)
#define f_add3(x,y,z) f_add(f_add(x, y), z)
#define f_unused(x) rb_funcall(x, rb_intern("never"), 0)
union DD { VALUE v; long n; };
static VALUE nest_sum(union DD *x) {
    return f_add3(x->v, INT2FIX(1), INT2FIX(2));
}
static VALUE mn_sum(VALUE self, VALUE obj) {
    union DD x;
    x.v = obj;
    return nest_sum(&x);
}
void Init_api_macro_nested(void) {
    VALUE m = rb_define_module("MacroNested");
    rb_define_module_function(m, "sum", mn_sum, 1);
}
