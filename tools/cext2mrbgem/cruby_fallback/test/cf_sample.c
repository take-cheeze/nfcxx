/* the original CRuby extension used by the prototype test: module CF with three module functions */
#include <ruby.h>

static VALUE cf_twice(VALUE self, VALUE x) { (void)self; return rb_funcall(x, '*', 1, INT2FIX(2)); }
static VALUE cf_echo(VALUE self, VALUE x) { (void)self; return x; }
static VALUE cf_div(VALUE self, VALUE a, VALUE b) { (void)self; return rb_funcall(a, '/', 1, b); }

void Init_cf_sample(void) {
  VALUE m = rb_define_module("CF");
  rb_define_module_function(m, "twice", cf_twice, 1);
  rb_define_module_function(m, "echo", cf_echo, 1);
  rb_define_module_function(m, "div", cf_div, 2);
}
