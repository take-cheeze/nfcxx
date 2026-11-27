#include <ruby.h>

/* rb_singleton_class returns a VALUE (mruby's mrb_singleton_class takes and returns an mrb_value): as the class of an alias it
   is wrapped as its class pointer (mrb_define_alias takes a struct RClass *) */
static VALUE klass;

static VALUE alloc_in(VALUE self) {
  return self;
}

void Init_api_singleton_alias(void) {
  klass = rb_define_class("ApiSingletonAlias", rb_cObject);
  rb_define_singleton_method(klass, "alloc_in", alloc_in, 0);
  rb_define_alias(rb_singleton_class(klass), "new_in", "alloc_in");
}
