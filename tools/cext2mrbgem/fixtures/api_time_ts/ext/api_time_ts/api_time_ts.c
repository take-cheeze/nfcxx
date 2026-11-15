#include <ruby.h>
#include <time.h>
static VALUE mTimeTs;
static VALUE tt_secs(VALUE self, VALUE t) {
    struct timespec ts = rb_time_timespec(t);
    return LONG2NUM((long)ts.tv_sec);
}
void Init_api_time_ts(void) {
    mTimeTs = rb_define_module("TimeTs");
    rb_define_module_function(mTimeTs, "secs", tt_secs, 1);
}
