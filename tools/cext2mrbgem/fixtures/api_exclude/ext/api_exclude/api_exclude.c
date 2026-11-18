#include <ruby.h>

void
Init_api_exclude(void)
{
    rb_define_class("ExcludeMain", rb_cObject);
}
