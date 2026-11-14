#include <ruby.h>

/* TypedData_Get_Type has no mruby equivalent in the map: it is refused, not passed through (api_map.json batch N10) */
static VALUE mApiDtr;

static VALUE api_make(VALUE self) {

    VALUE obj = TypedData_Get_Type(self);
    return obj;
}

void Init_api_dtype_refused(void) {
    mApiDtr = rb_define_module("ApiDtr");
    rb_define_module_function(mApiDtr, "make", api_make, 0);
}
