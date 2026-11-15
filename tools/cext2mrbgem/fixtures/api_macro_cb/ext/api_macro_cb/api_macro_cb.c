#include <ruby.h>
static VALUE mMc;

static void mc_call(VALUE m, int (*cb)(VALUE, VALUE), VALUE hash) {
    cb(m, hash);
}

static int mc_each(VALUE m, VALUE hash) {
    rb_hash_aset(hash, m, Qnil);
    return 1;
}

#define MC_RUN(m, h, c) mc_call(m, c, h)

static VALUE mc_go(VALUE self, VALUE m, VALUE h) {
    MC_RUN(m, h, mc_each);
    return Qnil;
}

void Init_api_macro_cb(void) {
    mMc = rb_define_module("MacroCb");
    rb_define_module_function(mMc, "go", mc_go, 2);
}
