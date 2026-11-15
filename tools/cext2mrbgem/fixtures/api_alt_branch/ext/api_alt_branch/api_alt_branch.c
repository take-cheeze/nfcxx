#include <ruby.h>
#define ALT_PACK
static VALUE mAltBranch;
#ifndef ALT_PACK
#define alt_pick(x) rb_funcall((x), rb_intern("to_s"), 0)
#else
#define alt_pick(x) rb_obj_as_string((x))
#endif
static VALUE alt_run(VALUE self, VALUE x) {
    return alt_pick(x);
}
void Init_api_alt_branch(void) {
    mAltBranch = rb_define_module("AltBranch");
    rb_define_module_function(mAltBranch, "run", alt_run, 1);
}
