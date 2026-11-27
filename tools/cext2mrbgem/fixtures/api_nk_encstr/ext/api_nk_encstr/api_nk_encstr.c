#include <ruby.h>

/* the encoding-tagged string and integer conversions of the api_map additions: an encoding is dropped (mruby strings
 * carry none), the bytes are kept; rb_Integer is Kernel#Integer */
static VALUE es_run(VALUE self, VALUE v, VALUE s) {
  VALUE i = rb_Integer(v);
  VALUE a = rb_enc_str_new_cstr("abc", rb_utf8_encoding());
  VALUE b = rb_external_str_new_with_enc("xy", 2, rb_utf8_encoding());
  VALUE out = rb_str_new_cstr("");
  rb_enc_str_buf_cat(out, "pq", 2, rb_utf8_encoding());
  return rb_ary_new3(4, i, a, b, out);
}

void Init_api_nk_encstr(void) {
  VALUE mod = rb_define_module("NkEncStr");
  rb_define_module_function(mod, "run", es_run, 2);
}
