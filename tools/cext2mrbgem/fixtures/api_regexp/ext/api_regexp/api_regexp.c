#include <ruby.h>

/* Regexp back-references through the onig gem's API (api_map.json batch N7) */
static VALUE mApiRe;

static VALUE api_nth(VALUE self, VALUE m) {
    return rb_reg_nth_match(1, m);
}

static VALUE api_last(VALUE self) {
    return rb_backref_get();
}

void Init_api_regexp(void) {
    mApiRe = rb_define_module("ApiRe");
    rb_define_module_function(mApiRe, "nth", api_nth, 1);
    rb_define_module_function(mApiRe, "last", api_last, 0);
}
