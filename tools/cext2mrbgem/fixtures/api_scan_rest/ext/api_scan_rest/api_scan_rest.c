#include <ruby.h>
static VALUE mSr;

static VALUE sr_split(int argc, VALUE *argv, VALUE self) {
    VALUE first, rest, blk;
    rb_scan_args(argc, argv, "1*&", &first, &rest, &blk);
    return rest;
}

void Init_api_scan_rest(void) {
    mSr = rb_define_module("ScanRest");
    rb_define_method(mSr, "split", sr_split, -1);
}
