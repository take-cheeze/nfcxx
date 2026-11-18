#include <ruby.h>

/* the tag is a stored integer, set from the parser's own constants, never from rb_type of a value */
struct item { unsigned char tag; };

static VALUE item_value(struct item *it)
{
    switch (it->tag) {
    case T_NIL: return Qnil;
    case T_STRING: return rb_str_new_cstr("s");
    default: return Qfalse;
    }
}

static VALUE m_nilish(VALUE self)
{
    struct item it;
    it.tag = T_NIL;
    return item_value(&it);
}

void Init_api_stored_tag(void)
{
    rb_define_method(rb_cObject, "nilish", m_nilish, 0);
}
