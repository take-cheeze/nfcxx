#include <ruby.h>

static VALUE bag_class;

/* a VALUE local assigned a class definition and also Qundef: it is an ordinary VALUE, not a struct RClass * */
static VALUE resolve_class(VALUE self, VALUE mod, VALUE name_sym)
{
    VALUE clas;
    ID    ci = SYM2ID(name_sym);

    if (rb_const_defined_at(mod, ci)) {
        clas = rb_const_get_at(mod, ci);
        if (!RB_TYPE_P(clas, T_CLASS)) {
            clas = Qundef;
        }
    } else {
        clas = rb_define_class_under(mod, "Made", bag_class);
    }
    return clas;
}

void Init_api_class_mixed(void)
{
    bag_class = rb_define_class("Bag", rb_cObject);
    rb_define_method(rb_cObject, "resolve_class", resolve_class, 2);
}
