#include <ruby.h>

static VALUE json_cls = Qnil;

struct cfg {
    const char *json_cls;
};

static VALUE same_class(VALUE self, VALUE a, VALUE b)
{
    struct cfg c;
    c.json_cls = "x";
    if (rb_obj_class(a) == rb_obj_class(b)) {
        return Qtrue;
    }
    if (rb_obj_class(a) != rb_cObject) {
        return Qfalse;
    }
    return json_cls;
}

void Init_api_value_cmp(void)
{
    rb_define_method(rb_cObject, "same_class", same_class, 2);
}
