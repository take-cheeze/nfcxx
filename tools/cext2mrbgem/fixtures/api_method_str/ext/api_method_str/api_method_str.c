#include <ruby.h>
static VALUE mMethodStr;
static VALUE ms_run(VALUE self, VALUE o, VALUE s) {
    ID id = rb_intern("arity");
    int ar = rb_obj_method_arity(o, id);
    VALUE big = rb_big2str(s, 10);
    VALUE str = rb_str_new_cstr("42");
    const char *cs = "42";
    VALUE n = rb_cstr2inum(cs, 10);
    VALUE sym = ST2FIX(3);
    VALUE sm = rb_io_write(s, big);
    (void)n; (void)sym; (void)sm;
    return INT2FIX(ar);
}
void Init_api_method_str(void) {
    mMethodStr = rb_define_module("MethodStr");
    rb_define_module_function(mMethodStr, "run", ms_run, 2);
}
