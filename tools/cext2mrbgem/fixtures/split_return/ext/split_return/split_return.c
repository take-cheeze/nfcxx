#include <ruby.h>

/* Definitions whose return type or name sits on another line. CRuby sources write them this way
 * (bigdecimal: "static inline VALUE" then "BigDecimal_double_fig(VALUE self)"; date: "static VALUE" then the name). */
static VALUE cSplit;

static inline VALUE
split_double(VALUE self)
{
    return rb_str_new_cstr("double");
}

static VALUE
split_load(VALUE self, VALUE str)
{
    return rb_str_new_cstr("load");
}

static VALUE
split_name(VALUE self)
{
    return rb_str_new_cstr("name");
}

static
VALUE split_storage(VALUE self)
{
    return rb_str_new_cstr("storage");
}

void Init_split_return(void) {
    cSplit = rb_define_class("SplitReturn", rb_cObject);
    rb_define_method(cSplit, "double", split_double, 0);
    rb_define_method(cSplit, "load", split_load, 1);
    rb_define_method(cSplit, "name", split_name, 0);
    rb_define_method(cSplit, "storage", split_storage, 0);
}
