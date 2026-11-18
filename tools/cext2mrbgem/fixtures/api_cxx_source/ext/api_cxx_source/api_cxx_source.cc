#include <ruby.h>

extern "C" {
  /* a C++ entry point: the converter reads the .cc source as C++ (the mruby build compiles it as C++) */
  static VALUE cxx_twice(VALUE self, VALUE n) {
    return INT2FIX(FIX2INT(n) * 2);
  }

  void Init_api_cxx_source() {
    VALUE c = rb_define_class("CxxSource", rb_cObject);
    rb_define_method(c, "twice", (VALUE (*)(...))cxx_twice, 1);
  }
}
