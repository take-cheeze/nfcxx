#include <ruby.h>
#include "st.h"

static VALUE lc_make(VALUE self)
{
    st_table *t = st_init_numhashtab();
    void *p = ruby_xmalloc2_unmapped(8);
    return self;
}

void Init_lowercase_api_refused(void)
{
    rb_define_method(rb_cObject, "lc_make", lc_make, 0);
}
