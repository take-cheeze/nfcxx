#include <ruby.h>
static VALUE mDeadUse;
static VALUE du_helper(VALUE x) {
    return rb_funcall(x, rb_intern("to_s"), 0);
}
#if 0
static VALUE du_dead(VALUE self, VALUE x) {
    return du_helper(x);
}
#endif
static VALUE du_live(VALUE self, VALUE x) {
    return rb_obj_as_string(x);
}
void Init_api_dead_use(void) {
    mDeadUse = rb_define_module("DeadUse");
    rb_define_module_function(mDeadUse, "live", du_live, 1);
}
