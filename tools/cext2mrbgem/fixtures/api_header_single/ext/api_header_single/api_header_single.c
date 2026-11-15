#include <ruby.h>
#include "helper.h"
static VALUE mHeaderSingle;
void Init_api_header_single(void) {
    mHeaderSingle = rb_define_module("HeaderSingle");
    rb_define_module_function(mHeaderSingle, "twice", hs_twice, 1);
}
