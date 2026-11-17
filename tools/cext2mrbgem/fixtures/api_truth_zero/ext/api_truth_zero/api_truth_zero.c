#include <ruby.h>

static VALUE m_check(VALUE self, VALUE obj, VALUE flag)
{
    int tz = 0;
    if (0 == tz && rb_funcall(obj, rb_intern("valid?"), 0)) {
        return Qtrue;
    }
    if (0 != flag) {
        return Qfalse;
    }
    return Qnil;
}

void Init_api_truth_zero(void)
{
    rb_define_method(rb_cObject, "check_truth", m_check, 2);
}
