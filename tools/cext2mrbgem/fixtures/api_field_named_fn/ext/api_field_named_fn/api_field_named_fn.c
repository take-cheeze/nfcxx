#include <ruby.h>

struct opts {
    char to_json;
    int  other;
};

static struct opts O;

static VALUE to_json(VALUE self)
{
    O.to_json = 1;
    return Qtrue;
}

void Init_api_field_named_fn(void)
{
    O.other = 0;
    rb_define_method(rb_cObject, "to_json", to_json, 0);
}
