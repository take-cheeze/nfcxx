#include <ruby.h>

/* TypedData_Make_Struct has no mruby equivalent in the map: it is refused, not passed through (api_map.json batch N10) */
static VALUE mApiDtr;

static VALUE api_make(VALUE self) {
    int *h;
    VALUE obj = TypedData_Make_Struct(self, int, NULL, h);
    return obj;
}

void Init_api_dtype_refused(void) {
    mApiDtr = rb_define_module("ApiDtr");
    rb_define_module_function(mApiDtr, "make", api_make, 0);
}
