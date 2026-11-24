#include <ruby.h>

/* a string's coderange (CRuby caches it: ASCII-only is ENC_CODERANGE_ASCIIONLY) and its encoding index (ENCODING_GET) */
static VALUE
cr_ascii(VALUE self, VALUE v)
{
    if (ENC_CODERANGE_ASCIIONLY(v) || ENCODING_GET(v) == 0)
        return Qtrue;
    return Qfalse;
}

void
Init_api_coderange(void)
{
    VALUE m = rb_define_module("CodeRange");
    rb_define_module_function(m, "ascii?", cr_ascii, 1);
}
