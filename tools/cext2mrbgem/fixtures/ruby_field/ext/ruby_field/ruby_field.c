#include <ruby.h>

/* A struct field named like a CRuby API (ruby_sd, as pg's pg_cancel_connection.c has): its declaration and its member
   accesses are the input's own names, so no unknown-API refusal. A file-scope variable declared with a ruby_ name is the
   input's too. */
typedef struct {
    int ruby_sd;
    VALUE holder;
} rf_state;

static int ruby_count = 0;

static VALUE rf_member(VALUE self) {
    rf_state st;
    rf_state *p = &st;
    p->ruby_sd = 7;
    st.ruby_sd = p->ruby_sd + 1;
    ruby_count++;
    return LONG2NUM(st.ruby_sd + ruby_count);
}

void Init_ruby_field(void) {
    VALUE c = rb_define_class("RubyField", rb_cObject);
    rb_define_method(c, "member", rf_member, 0);
}
