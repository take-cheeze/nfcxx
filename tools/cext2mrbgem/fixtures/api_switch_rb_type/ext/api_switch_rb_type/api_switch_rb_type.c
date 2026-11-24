#include <ruby.h>
#include <ruby/re.h>
static VALUE mSt;

/* the same switch with rb_type(v) as its subject (a function with the state's place, as a hash callback has it) */
static VALUE st_kind(VALUE self, VALUE v) {
    switch (rb_type(v)) {
    case T_REGEXP: return rb_str_new_cstr("regexp");
    case T_STRING: return rb_str_new_cstr("string");
    default: return rb_str_new_cstr("other");
    }
}

void Init_api_switch_rb_type(void) {
    mSt = rb_define_module("SwitchRbType");
    rb_define_module_function(mSt, "kind", st_kind, 1);
}
