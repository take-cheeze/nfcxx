#include <ruby.h>
#include "ncmr.h"

/* control: NCMR_OFFSET's body is not a cast of its parameter, so the macro is not expanded: the argument is kept as the call */
static const rb_data_type_t ncmr_type = {
  .wrap_struct_name = "ncmr",
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE ncmr_wrap(VALUE klass, VALUE name) {
  const char *p = StringValueCStr(name);
  return TypedData_Wrap_Struct(klass, &ncmr_type, NCMR_OFFSET(p));
}

void Init_nested_cast_macro_refused(void) {
  VALUE m = rb_define_module("NestedCastMacroRefused");
  rb_define_singleton_method(m, "wrap", ncmr_wrap, 1);
}
