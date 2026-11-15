#include <ruby.h>
static VALUE mFixnumBound;
static VALUE fb_fits(VALUE self, VALUE v) {
    long n = NUM2LONG(v);
    if (n > FIXNUM_MAX || n < FIXNUM_MIN) return Qfalse;
    return Qtrue;
}
void Init_api_fixnum_bound(void) {
    mFixnumBound = rb_define_module("FixnumBound");
    rb_define_module_function(mFixnumBound, "fits", fb_fits, 1);
}
