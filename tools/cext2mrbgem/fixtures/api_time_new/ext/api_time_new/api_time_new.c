#include <ruby.h>
#include <time.h>
static VALUE mTimeNew;
static VALUE tn_make(VALUE self, VALUE sec, VALUE off) {
    struct timespec ts;
    ts.tv_sec = NUM2LONG(sec);
    ts.tv_nsec = 0;
    return rb_time_timespec_new(&ts, NUM2INT(off));
}
void Init_api_time_new(void) {
    mTimeNew = rb_define_module("TimeNew");
    rb_define_module_function(mTimeNew, "make", tn_make, 2);
}
