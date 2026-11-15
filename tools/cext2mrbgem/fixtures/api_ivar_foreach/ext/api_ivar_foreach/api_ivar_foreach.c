#include <ruby.h>
static VALUE mIvarForeach;
static int iv_count_cb(ID key, VALUE value, VALUE acc) {
    VALUE *count = (VALUE *)acc;
    if (rb_id2name(key)[0] != '@') return ST_CONTINUE;
    *count = INT2FIX(FIX2INT(*count) + 1);
    return ST_CONTINUE;
}
static VALUE iv_count(VALUE self, VALUE obj) {
    VALUE count = INT2FIX(0);
    rb_ivar_foreach(obj, iv_count_cb, (VALUE)&count);
    return count;
}
void Init_api_ivar_foreach(void) {
    mIvarForeach = rb_define_module("IvarForeach");
    rb_define_module_function(mIvarForeach, "count", iv_count, 1);
}
