#include <ruby.h>

/* rb_reg_new: a regular expression from a source string and options (CRuby's Regexp). */
static VALUE
rn_match(VALUE self, VALUE src)
{
    VALUE pat;
    pat = rb_reg_new(RSTRING_PTR(src), RSTRING_LEN(src), 1);
    return pat;
}

void
Init_api_reg_new(void)
{
    VALUE m = rb_define_module("RegNew");
    rb_define_module_function(m, "build", rn_match, 1);
}
