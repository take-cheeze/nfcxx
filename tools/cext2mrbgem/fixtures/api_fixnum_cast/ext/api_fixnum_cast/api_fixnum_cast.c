#include <ruby.h>

/* a fixnum VALUE read as an integer inside its FIXNUM_P branch (date's hash of a day number) */
static VALUE
fc_hash(VALUE self, VALUE nth)
{
    st_index_t h[2];
    if (FIXNUM_P(nth)) {
        h[1] = (st_index_t)nth;
    }
    else {
        h[1] = 0;
    }
    return LONG2NUM((long)h[1]);
}

void
Init_api_fixnum_cast(void)
{
    VALUE m = rb_define_module("FixnumCast");
    rb_define_module_function(m, "hash_of", fc_hash, 1);
}
