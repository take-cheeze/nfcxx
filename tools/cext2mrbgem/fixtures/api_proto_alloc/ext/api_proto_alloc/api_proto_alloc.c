#include <ruby.h>

/* a prototype with unnamed VALUE parameters of a registered method: its header is the definition's (not refused) */
static VALUE thing_alloc(VALUE);

static VALUE thing_alloc(VALUE klass) {
  return klass;
}

void Init_api_proto_alloc(void) {
  rb_define_alloc_func(rb_cObject, thing_alloc);
}
