#include <ruby.h>
#include "xfile_cache.h"

static VALUE mXf;

static VALUE xf_make(VALUE self) {
    VALUE obj = rb_data_typed_object_wrap(mXf, 0, &xf_type);
    return obj;
}

void Init_api_dtype_xfile(void) {
    mXf = rb_define_module("DtXfile");
    rb_define_module_function(mXf, "make", xf_make, 0);
}
