#include <ruby.h>

/* api_map.json batch N17: rb_ary_pop, rb_str_subseq, rb_intern3 (encoding dropped), RB_UNUSED_VAR,
 * RUBY_TYPED_FROZEN_SHAREABLE (0), rb_deprecate_constant (no-op) */
static VALUE mBatch;

static VALUE b_first(VALUE self, VALUE ary) {
    return rb_ary_pop(ary);
}

static VALUE b_sub(VALUE self, VALUE str) {
    return rb_str_subseq(str, 1, 2);
}

static VALUE b_unused(VALUE self, VALUE RB_UNUSED_VAR(unused)) {
    return Qnil;
}

static VALUE b_intern(VALUE self, VALUE s) {
    const char *p = "name";
    void *enc = NULL;
    ID id = rb_intern3(p, 4, enc);
    (void)id;
    return s;
}

static int b_flags(void) {
    return RUBY_TYPED_FROZEN_SHAREABLE;
}

void Init_api_batch_n17(void) {
    mBatch = rb_define_module("BatchN17");
    rb_deprecate_constant(mBatch, "OLD");
    rb_define_module_function(mBatch, "first", b_first, 1);
    rb_define_module_function(mBatch, "sub", b_sub, 1);
    rb_define_module_function(mBatch, "unused", b_unused, 1);
    rb_define_module_function(mBatch, "intern", b_intern, 1);
    (void)b_flags;
}
