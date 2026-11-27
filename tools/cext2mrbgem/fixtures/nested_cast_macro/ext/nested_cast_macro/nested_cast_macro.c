#include <ruby.h>
#include <stdint.h>
#include "ncm.h"

/* the gem-local cast macro is a whole argument of TypedData_Wrap_Struct: its expansion is a plain cast of the argument, so the
   argument is ((void *)(uintptr_t)(p)) and the wrap converts */
static const rb_data_type_t ncm_type = {
  .wrap_struct_name = "ncm",
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE ncm_wrap(VALUE klass, VALUE name) {
  const char *p = StringValueCStr(name);
  if (NULL == p) { return Qnil; }
  return TypedData_Wrap_Struct(klass, &ncm_type, NCM_DISCARD(void *, p));
}

void Init_nested_cast_macro(void) {
  VALUE m = rb_define_module("NestedCastMacro");
  rb_define_singleton_method(m, "wrap", ncm_wrap, 1);
}
