#include <ruby.h>
static VALUE mMr;

static int mr_match(VALUE str, VALUE hash, int (*cb)(VALUE, VALUE)) {
    return cb(str, hash);
}

#define MR_MATCH(s,c) \
do { \
    return mr_match(s, hash, c); \
} while (0)

static int mr_each(VALUE m, VALUE hash) {
    rb_hash_aset(hash, m, Qnil);
    return 1;
}

static int mr_run2(VALUE m, VALUE hash) {
    MR_MATCH(m, mr_each);
}

static VALUE mr_go(VALUE self, VALUE m, VALUE hash) {
    return mr_run2(m, hash) ? Qtrue : Qfalse;
}

void Init_api_macro_ret_cb(void) {
    mMr = rb_define_module("MacroRetCb");
    rb_define_module_function(mMr, "go", mr_go, 2);
}
