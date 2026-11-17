#include <ruby.h>

/* a VALUE tested as a condition: CRuby's nonzero word (Qnil is nonzero), which the fork's VALUE struct has no exact test of */
static VALUE
m_truth(VALUE self, VALUE v)
{
    if (v) return Qtrue;
    return Qfalse;
}

void
Init_api_value_if(void)
{
    VALUE c = rb_define_class("ValueIf", rb_cObject);
    rb_define_method(c, "truth", m_truth, 1);
}
