#include <ruby.h>

typedef struct { int x; } zbox;

static const rb_data_type_t zb_type = {
    "zb",
    {NULL, RUBY_TYPED_DEFAULT_FREE, NULL,},
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE m_make(VALUE self)
{
    size_t sz = sizeof(zbox);
    VALUE obj = rb_data_typed_object_zalloc(rb_cObject, sz, &zb_type);
    return obj;
}

static VALUE m_id(VALUE self, VALUE v)
{
    ID f;
    f = (ID)rb_intern("a");
    return ID2SYM(f);
}

void Init_api_zalloc_idcast(void)
{
    rb_define_method(rb_cObject, "make_zb", m_make, 0);
    rb_define_method(rb_cObject, "id_of", m_id, 1);
}
