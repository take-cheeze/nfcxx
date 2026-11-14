#include <ruby.h>

/* a callback parameter forwarded to another function: fw_outer passes its own parameter cb to fw_inner, which calls it.
 * The callbacks passed to fw_outer are threaded, and fw_inner's parameter takes the state too */
static VALUE mFW;

static VALUE fw_inner(VALUE (*cb)(VALUE), VALUE v) {
    return cb(v);
}

static VALUE fw_outer(VALUE (*cb)(VALUE), VALUE v) {
    return fw_inner(cb, v);
}

static VALUE fw_pick(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return v;
}

static VALUE fw_run(VALUE self, VALUE v) {
    return fw_outer(fw_pick, v);
}

void Init_api_fnptr_forward(void) {
    mFW = rb_define_module("FnptrForward");
    rb_define_module_function(mFW, "run", fw_run, 1);
}
