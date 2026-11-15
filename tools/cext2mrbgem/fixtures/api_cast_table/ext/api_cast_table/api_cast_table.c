#include <ruby.h>
static VALUE mCt;

struct ct_funcs {
    VALUE (*secs)(void *dat);
    VALUE (*msecs)(void *dat);
};
struct ct_box {
    void *dat;
    const struct ct_funcs *funcs;
};

static VALUE ct_secs(void *dat) {
    return rb_str_new_cstr("s");
}

static VALUE ct_msecs(void *dat) {
    return rb_funcall(ct_secs(dat), rb_intern("to_s"), 0);
}

static const struct ct_funcs ct_table = {
    (VALUE (*)(void *))ct_secs,
    (VALUE (*)(void *))ct_msecs,
};

static VALUE ct_run(VALUE self, VALUE v) {
    struct ct_box box;
    box.dat = NULL;
    (void)v;
    box.funcs = &ct_table;
    return box.funcs->msecs(box.dat);
}

void Init_api_cast_table(void) {
    mCt = rb_define_module("CastTable");
    rb_define_module_function(mCt, "run", ct_run, 1);
}
