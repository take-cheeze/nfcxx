#include <ruby.h>

/* a hash over words that include a VALUE-returning call's value: the function hashes the array (rb_memhash), so the VALUE is
   hashed by value (its integer if a fixnum, else its hash method), as Date#hash takes its sf */
static VALUE
hv_sf(VALUE self)
{
    return rb_str_new_cstr("sf");
}

static VALUE
hv_hash(VALUE self, VALUE obj)
{
    st_index_t h[2];
    h[0] = 1;
    h[1] = hv_sf(obj);
    return LONG2NUM((long)rb_memhash(h, sizeof(h)));
}

void
Init_api_hash_value(void)
{
    VALUE m = rb_define_module("HashValue");
    rb_define_module_function(m, "hash_of", hv_hash, 1);
}
