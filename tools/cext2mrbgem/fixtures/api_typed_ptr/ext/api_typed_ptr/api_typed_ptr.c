#include <ruby.h>

/* RTYPEDDATA_DATA (api_map.json, batch C1): the data pointer of a wrapped object, read and cleared. */
static VALUE mApiPtr;

static VALUE api_has(VALUE self, VALUE obj) {
    void *p = RTYPEDDATA_DATA(obj);
    return p == NULL ? Qfalse : Qtrue;
}

static VALUE api_clear(VALUE self, VALUE obj) {
    RTYPEDDATA_DATA(obj) = NULL;
    return obj;
}

void Init_api_typed_ptr(void) {
    mApiPtr = rb_define_module("ApiPtr");
    rb_define_module_function(mApiPtr, "has", api_has, 1);
    rb_define_module_function(mApiPtr, "clear", api_clear, 1);
}
