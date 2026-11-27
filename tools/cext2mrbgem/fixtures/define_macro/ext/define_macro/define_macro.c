#include <ruby.h>

/* RDM_INFO_VERSION is a build define (--define RDM_INFO_VERSION=1.8.1, as racc's extconf sets RACC_INFO_VERSION): the
 * converter must know it as a macro of the build, not refuse it as an unknown CRuby identifier. */
#define DM_STR_(x) #x
#define DM_STR(x) DM_STR_(x)
#define DM_VERSION DM_STR(RDM_INFO_VERSION)

static VALUE
dm_version(VALUE self)
{
    return rb_str_new2(DM_VERSION);
}

void
Init_define_macro(void)
{
    VALUE c = rb_define_class("DefineMacro", rb_cObject);
    rb_define_method(c, "version", dm_version, 0);
}
