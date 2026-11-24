#include <ruby.h>

/* a later declarator of a declaration (const char *s1, *s2;) shadows a VALUE s2 of the function: its if (s2) is a pointer test */
static VALUE
dc_check(VALUE self, VALUE str)
{
    VALUE s2 = str;
    const char *cs = RSTRING_PTR(str);
    {
        const char *s1, *s2;
        s1 = cs;
        s2 = strchr(s1, ':');
        if (s2) {
            s2++;
            return rb_str_new_cstr(s2);
        }
    }
    return s2;
}

void
Init_api_decl_comma(void)
{
    VALUE m = rb_define_module("DeclComma");
    rb_define_module_function(m, "check", dc_check, 1);
}
