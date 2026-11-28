/* the original CRuby extension used by the prototype test: module CF with three module functions, and class CF::Counter whose
 * state (@n) lives in the CRuby object, so an mruby side can only hold it through a handle */
#include <ruby.h>

static VALUE cf_twice(VALUE self, VALUE x) { (void)self; return rb_funcall(x, '*', 1, INT2FIX(2)); }
static VALUE cf_echo(VALUE self, VALUE x) { (void)self; return x; }
static VALUE cf_div(VALUE self, VALUE a, VALUE b) { (void)self; return rb_funcall(a, '/', 1, b); }

static VALUE cnt_init(VALUE self, VALUE n) { rb_iv_set(self, "@n", n); return self; }
static VALUE cnt_add(VALUE self, VALUE x) {
  VALUE s = rb_funcall(rb_iv_get(self, "@n"), '+', 1, x);
  rb_iv_set(self, "@n", s);
  return s;
}

void Init_cf_sample(void) {
  VALUE m = rb_define_module("CF");
  rb_define_module_function(m, "twice", cf_twice, 1);
  rb_define_module_function(m, "echo", cf_echo, 1);
  rb_define_module_function(m, "div", cf_div, 2);
  VALUE c = rb_define_class_under(m, "Counter", rb_cObject);
  rb_define_method(c, "initialize", cnt_init, 1);
  rb_define_method(c, "add", cnt_add, 1);
}
