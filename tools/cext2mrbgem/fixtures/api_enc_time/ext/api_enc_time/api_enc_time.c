#include <ruby.h>
static VALUE mEncTime;
static VALUE et_run(VALUE self, VALUE s) {
    const char *p = "abc";
    void *enc = 0;
    VALUE r = rb_enc_interned_str(p, 3, enc);
    if (rb_enc_str_asciicompat_p(s)) return r;
    return s;
}
static VALUE et_time(VALUE self, VALUE s) {
    long sec = NUM2LONG(s);
    long nsec = 1500;
    return rb_time_nano_new(sec, nsec);
}
void Init_api_enc_time(void) {
    mEncTime = rb_define_module("EncTime");
    rb_define_module_function(mEncTime, "run", et_run, 1);
    rb_define_module_function(mEncTime, "time", et_time, 1);
}
