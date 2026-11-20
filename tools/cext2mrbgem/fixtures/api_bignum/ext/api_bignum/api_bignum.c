#include <ruby.h>

/* Bignum conversions: CRuby's rb_big2ll, rb_big2ull, rb_ull2inum, rb_absint_size, rb_big_cmp and RBIGNUM_*_P */
static VALUE
bn_to_ll(VALUE self, VALUE v)
{
    return LL2NUM(rb_big2ll(v));
}

static VALUE
bn_to_ull(VALUE self, VALUE v)
{
    return ULL2NUM(rb_big2ull(v));
}

static VALUE
bn_from_ull(VALUE self, VALUE v)
{
    return rb_ull2inum((unsigned long long)NUM2ULL(v));
}

static VALUE
bn_size(VALUE self, VALUE v)
{
    int nlz = 0;
    size_t n = rb_absint_size(v, &nlz);
    return rb_ary_new3(2, SIZET2NUM(n), INT2NUM(nlz));
}

static VALUE
bn_cmp(VALUE self, VALUE a, VALUE b)
{
    return rb_big_cmp(a, b);
}

static VALUE
bn_sign(VALUE self, VALUE v)
{
    if (RBIGNUM_POSITIVE_P(v)) return INT2FIX(1);
    if (RBIGNUM_NEGATIVE_P(v)) return INT2FIX(-1);
    return INT2FIX(0);
}

void
Init_api_bignum(void)
{
    VALUE m = rb_define_module("BigNum");
    rb_define_module_function(m, "to_ll", bn_to_ll, 1);
    rb_define_module_function(m, "to_ull", bn_to_ull, 1);
    rb_define_module_function(m, "from_ull", bn_from_ull, 1);
    rb_define_module_function(m, "size", bn_size, 1);
    rb_define_module_function(m, "cmp", bn_cmp, 2);
    rb_define_module_function(m, "sign", bn_sign, 1);
}
