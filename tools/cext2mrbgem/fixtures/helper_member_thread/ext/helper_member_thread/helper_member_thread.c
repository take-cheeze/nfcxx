#include <ruby.h>
#include <time.h>

static VALUE mHMT;

/* tm_isdst is also a member of struct tm (declared outside the input). The member accesses t.tm_isdst are not uses of
   the helper, so its only uses are the direct calls from a registered method and it takes mrb */
static VALUE tm_isdst(VALUE s) {
    return rb_str_new_cstr("dst");
}

static VALUE hmt_run(VALUE self, VALUE s) {
    struct tm t;
    t.tm_isdst = 0;
    return tm_isdst(s);
}

void Init_helper_member_thread(void) {
    mHMT = rb_define_module("HelperMemberThread");
    rb_define_module_function(mHMT, "run", hmt_run, 1);
}
