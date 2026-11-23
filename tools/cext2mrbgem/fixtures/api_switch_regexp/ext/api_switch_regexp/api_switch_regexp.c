#include <ruby.h>
#include <ruby/re.h>
static VALUE mSr;

/* the CRuby switch on a value's type: a Regexp is a T_REGEXP label, which is the Regexp class of the mruby-onig-regexp gem */
static VALUE sr_kind(VALUE self, VALUE v) {
    switch (TYPE(v)) {
    case T_REGEXP: return rb_str_new_cstr("regexp");
    case T_STRING: return rb_str_new_cstr("string");
    default: return rb_str_new_cstr("other");
    }
}

void Init_api_switch_regexp(void) {
    mSr = rb_define_module("SwitchRegexp");
    rb_define_module_function(mSr, "kind", sr_kind, 1);
}
