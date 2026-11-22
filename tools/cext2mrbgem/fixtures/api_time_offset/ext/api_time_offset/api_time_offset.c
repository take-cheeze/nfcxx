#include <ruby.h>
#include <limits.h>

/* rb_time_timespec_new: a fixed UTC offset, and CRuby's sentinels for local time and UTC (INT_MAX, INT_MAX-1). */
static VALUE
to_time(VALUE self, VALUE sec_v, VALUE off_v)
{
    struct timespec ts;
    ts.tv_sec = NUM2LONG(sec_v);
    ts.tv_nsec = 500000000;
    return rb_time_timespec_new(&ts, NUM2INT(off_v));
}

void
Init_api_time_offset(void)
{
    VALUE m = rb_define_module("TimeOffset");
    rb_define_module_function(m, "at", to_time, 2);
}
