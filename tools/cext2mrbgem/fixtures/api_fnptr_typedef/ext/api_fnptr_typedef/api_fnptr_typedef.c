#include <ruby.h>
#include <string.h>
typedef void (*DumpFunc)(VALUE obj, int depth);
struct Holder { VALUE obj; DumpFunc dump; };
static VALUE mFnptrTypedef;
static void ftd_attrs(VALUE obj, int depth) {
    rb_funcall(obj, rb_intern("to_s"), 0);
}
static VALUE ftd_run(VALUE self, VALUE obj) {
    struct Holder h;
    h.obj = obj;
    h.dump = ftd_attrs;
    if (h.dump == ftd_attrs) {
        h.dump(h.obj, 0);
    }
    return Qtrue;
}
void Init_api_fnptr_typedef(void) {
    mFnptrTypedef = rb_define_module("FnptrTypedef");
    rb_define_module_function(mFnptrTypedef, "run", ftd_run, 1);
}
