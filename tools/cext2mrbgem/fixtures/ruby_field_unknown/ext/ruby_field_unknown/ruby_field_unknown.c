#include <ruby.h>

/* The struct field ruby_sd is the input's own name and is not refused, but a call to an undeclared CRuby API still is. */
typedef struct {
    int ruby_sd;
} rfu_state;

static VALUE rfu_call(VALUE self) {
    rfu_state st;
    st.ruby_sd = 1;
    ruby_nosuch_api(st.ruby_sd);
    return self;
}

void Init_ruby_field_unknown(void) {
    VALUE c = rb_define_class("RubyFieldUnknown", rb_cObject);
    rb_define_method(c, "call", rfu_call, 0);
}
