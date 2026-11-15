#include <ruby.h>
static VALUE mIvarHelper;
static int ih_cb(ID key, VALUE value, VALUE ov) {
    VALUE *acc = (VALUE *)ov;
    if (rb_id2name(key)[0] == '@') *acc = INT2FIX(FIX2INT(*acc) + 1);
    return ST_CONTINUE;
}
static void ih_attrs(VALUE obj, VALUE *acc) {
    rb_ivar_foreach(obj, ih_cb, (VALUE)acc);
}
static VALUE ih_count(VALUE self, VALUE obj) {
    VALUE count = INT2FIX(0);
    ih_attrs(obj, &count);
    return count;
}
void Init_api_ivar_helper(void) {
    mIvarHelper = rb_define_module("IvarHelper");
    rb_define_module_function(mIvarHelper, "count", ih_count, 1);
}
