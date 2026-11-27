#include <ruby.h>

/* a VALUE compared through a dereferenced VALUE pointer: the identity test (both operands are VALUEs) */
static VALUE uncompilable_marker;

static int fetch(VALUE *output_data) {
  if (*output_data == uncompilable_marker) return 1;
  return 0;
}

void Init_api_deref_cmp(void) {
  uncompilable_marker = rb_const_get(rb_cObject, rb_intern("Object"));
  rb_global_variable(&uncompilable_marker);
}
