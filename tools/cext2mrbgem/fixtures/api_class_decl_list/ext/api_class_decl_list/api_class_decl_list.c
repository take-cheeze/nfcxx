#include <ruby.h>
#include "api_class_decl_list.h"

static VALUE m_b(VALUE self) { return cB; }

void Init_api_class_decl_list(void) {
    mM = rb_define_module("MClassDeclList");
    cA = rb_define_class("AClassDeclList", rb_cObject);
    cB = rb_define_class_under(mM, "BClassDeclList", cA);
    cStandardError = rb_const_get(rb_cObject, rb_intern("StandardError"));
    rb_define_method(cA, "b", m_b, 0);
}
