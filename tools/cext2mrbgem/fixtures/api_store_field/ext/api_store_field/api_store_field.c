#include <ruby.h>

/* a callback stored in a struct field (the store is a use of the parameter, the field's calls are its uses) */
struct sf_box {
    VALUE (*fn)(const char *str, size_t len);
};

static struct sf_box sf_cur;

static VALUE
sf_make(const char *str, size_t len)
{
    return rb_str_new(str, (long)len);
}

static struct sf_box
sf_set(VALUE (*fn)(const char *str, size_t len))
{
    sf_cur.fn = fn;
    return sf_cur;
}

static VALUE
sf_use(const char *str, size_t len)
{
    return sf_cur.fn(str, len);
}

static VALUE
m_store(VALUE self, VALUE s)
{
    sf_set(sf_make);
    return sf_use(RSTRING_PTR(s), (size_t)RSTRING_LEN(s));
}

void
Init_api_store_field(void)
{
    VALUE c = rb_define_class("StoreField", rb_cObject);
    rb_define_method(c, "store", m_store, 1);
}
