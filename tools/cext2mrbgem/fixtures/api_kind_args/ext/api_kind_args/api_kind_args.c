#include <ruby.h>
struct KindVal { VALUE val; };
static VALUE mKindArgs;
static VALUE kind_exc(VALUE self, VALUE obj) {
    struct KindVal p;
    p.val = obj;
    if (rb_obj_is_kind_of(p.val, rb_eException)) return Qtrue;
    return Qfalse;
}
void Init_api_kind_args(void) {
    mKindArgs = rb_define_module("KindArgs");
    rb_define_module_function(mKindArgs, "kind_exc", kind_exc, 1);
}
