#include <ruby.h>

/* a helper that needs the state (a funcall); a macro calls it by a pasted name (xy##_helper), so the call passes mrb */
static VALUE
xy_helper(VALUE v)
{
    return rb_funcall(v, rb_intern("to_s"), 0);
}

#define CALL_HELPER(s, v) s##_helper(v)

static VALUE
m_paste(VALUE self, VALUE v)
{
    return CALL_HELPER(xy, v);
}

void
Init_api_paste_macro(void)
{
    VALUE c = rb_define_class("PasteMacro", rb_cObject);
    rb_define_method(c, "paste", m_paste, 1);
}
