#include <ruby.h>
static VALUE errinfo_get(VALUE self) { return rb_errinfo(); }
void Init_api_errinfo(void) { VALUE m = rb_define_module("ErrInfo"); rb_define_module_function(m, "get", errinfo_get, 0); }
