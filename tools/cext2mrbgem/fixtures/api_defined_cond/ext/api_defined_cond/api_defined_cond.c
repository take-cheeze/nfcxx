#include <ruby.h>

/* a condition of defined() atoms: _LIBC is defined only while glibc itself is compiled, so this block is inactive in a
   normal build; its CRuby call (no api_map entry) must not be refused */
#if defined(__GLIBC__) && defined(_LIBC)
static VALUE only_in_libc(VALUE self, VALUE s) { return rb_str_dump_nonexistent_api(s); }
#endif

static VALUE m_plain(VALUE self) { return INT2FIX(1); }

void
Init_api_defined_cond(void)
{
    VALUE c = rb_define_class("DefinedCond", rb_cObject);
    rb_define_method(c, "plain", m_plain, 0);
}
