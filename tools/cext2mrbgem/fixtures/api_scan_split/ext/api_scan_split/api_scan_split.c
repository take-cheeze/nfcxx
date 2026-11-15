#include <ruby.h>
static VALUE mScanSplit;
static VALUE ss_pick(int argc, VALUE *argv, VALUE self) {
    VALUE first, second;
    rb_scan_args(argc, argv, "11", &first, &second);
    return NIL_P(second) ? first : second;
}
static VALUE ss_call(VALUE self, VALUE a) {
    return ss_pick(1, &a, self);
}
void Init_api_scan_split(void) {
    mScanSplit = rb_define_module("ScanSplit");
    rb_define_module_function(mScanSplit, "pick", ss_pick, -1);
    rb_define_module_function(mScanSplit, "call", ss_call, 1);
}
