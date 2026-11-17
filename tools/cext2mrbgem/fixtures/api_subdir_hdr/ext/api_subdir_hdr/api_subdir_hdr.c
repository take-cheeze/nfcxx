#include <ruby.h>
#include "api/subdir_public.h"

static VALUE
m_answer(VALUE self)
{
    return INT2FIX(SUBDIR_ANSWER);
}

void
Init_api_subdir_hdr(void)
{
    VALUE c = rb_define_class("SubdirHdr", rb_cObject);
    rb_define_method(c, "answer", m_answer, 0);
}
