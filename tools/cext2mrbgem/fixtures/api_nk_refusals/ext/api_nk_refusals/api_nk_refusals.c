#include <ruby.h>

/* converter false refusals (nokogiri): rb_intern_const is a name like rb_intern; the count of rb_ary_new3 may carry a
 * (rb_len_t) cast; rb_iv_get's name argument is found past a nested call; E_RUNTIME_ERROR is an exception class;
 * a data type without a .function group (no mark and no free); a gem macro under a build switch with no other branch */
#ifndef NK_NOT_A_SWITCH
#define RBSTR_NK(x) ((x) ? rb_str_new_cstr(x) : Qnil)
#endif

typedef struct { int n; } nk_box;

static const rb_data_type_t nk_plain_type = {
  .wrap_struct_name = "nk_plain",
  .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE nk_funcall(VALUE self, VALUE obj) {
  VALUE a = rb_funcall(obj, rb_intern_const("[]"), 1, INT2FIX(0));
  VALUE b = rb_funcall(obj, rb_intern_const("document"), 0);
  return rb_ary_new3((rb_len_t)2, a, b);
}

static VALUE nk_iv(VALUE self, VALUE obj) {
  return rb_iv_get(rb_ary_entry(obj, 0), "@nk_flag");
}

static VALUE nk_exc(VALUE self, VALUE msg) {
  VALUE s = RBSTR_NK("z");
  (void)s;
  rb_exc_raise(rb_exc_new3(rb_eRuntimeError, msg));
  return Qnil;
}

void Init_api_nk_refusals(void) {
  VALUE mod = rb_define_module("NkRefusals");
  rb_define_module_function(mod, "funcall", nk_funcall, 1);
  rb_define_module_function(mod, "iv", nk_iv, 1);
  rb_define_module_function(mod, "exc", nk_exc, 1);
  (void)nk_plain_type;
}
