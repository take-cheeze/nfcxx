#include <ruby.h>
static VALUE m(VALUE self, VALUE sc) {
    VALUE clas = sc;
    if (Qtrue == rb_class_inherited_p(clas, rb_mEnumerable)) return Qtrue;
    return Qfalse;
}
void Init_api_module_arg(void) { rb_define_method(rb_cObject, "m", m, 1); }
