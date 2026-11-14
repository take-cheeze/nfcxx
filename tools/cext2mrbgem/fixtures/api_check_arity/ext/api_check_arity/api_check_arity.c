#include <ruby.h>
static VALUE mCheckArity;
static VALUE ca_pick(int argc, VALUE *argv, VALUE self) {
    rb_check_arity(argc, 0, 1);
    return argc > 0 ? argv[0] : Qnil;
}
void Init_api_check_arity(void) {
    mCheckArity = rb_define_module("CheckArity");
    rb_define_module_function(mCheckArity, "pick", ca_pick, -1);
}
