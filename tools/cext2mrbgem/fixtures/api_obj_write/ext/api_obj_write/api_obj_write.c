#include <ruby.h>
struct OwBox { VALUE v; };
static VALUE mObjWrite;
static VALUE ow_canon(VALUE x) {
    return x;
}
static VALUE ow_set(VALUE self, VALUE holder, VALUE val) {
    struct OwBox *box = (struct OwBox *)DATA_PTR(holder);
    RB_OBJ_WRITE(holder, &box->v, ow_canon(val));
    return box->v;
}
void Init_api_obj_write(void) {
    mObjWrite = rb_define_module("ObjWrite");
    rb_define_module_function(mObjWrite, "set", ow_set, 2);
}
