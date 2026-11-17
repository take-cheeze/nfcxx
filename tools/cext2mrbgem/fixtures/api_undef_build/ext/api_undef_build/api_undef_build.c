#include <ruby.h>

static VALUE
ub_plain(VALUE self)
{
    return Qnil;
}

#ifdef UB_TEST_ONLY_METHODS
static VALUE
ub_test_only(VALUE self)
{
    return Qtrue;
}
#endif

void
Init_api_undef_build(void)
{
    VALUE c = rb_define_class("UndefBuild", rb_cObject);
    rb_define_method(c, "plain", ub_plain, 0);
#ifdef UB_TEST_ONLY_METHODS
    rb_define_method(c, "test_only", ub_test_only, 0);
#endif
}
