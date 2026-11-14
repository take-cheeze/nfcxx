#include <ruby.h>

/* api_map.json batch N18: RSTRING_END is a template over RSTRING_PTR and RSTRING_LEN; RARRAY_CONST_PTR maps to the
 * mruby RARRAY_PTR macro */
static VALUE mBatch18;

static VALUE b_end_ptr(VALUE self, VALUE str) {
    char *e = RSTRING_END(str);
    return rb_str_new(e, 0);
}

static VALUE b_first_item(VALUE self, VALUE ary) {
    const VALUE *items = RARRAY_CONST_PTR(ary);
    return items[0];
}

void Init_api_batch_n18(void) {
    mBatch18 = rb_define_module("BatchN18");
    rb_define_module_function(mBatch18, "end_ptr", b_end_ptr, 1);
    rb_define_module_function(mBatch18, "first_item", b_first_item, 1);
}
