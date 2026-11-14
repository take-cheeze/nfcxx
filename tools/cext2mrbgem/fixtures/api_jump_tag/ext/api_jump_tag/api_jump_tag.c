#include <ruby.h>

/* rb_jump_tag re-raises after rb_protect, and rb_match_busy is a hint with no effect in mruby (api_map.json batch N8) */
static VALUE mApiJump;

static VALUE api_rethrow(VALUE self, VALUE m) {
    int state = 0;
    rb_match_busy(m);
    rb_jump_tag(state);
    return Qnil;
}

void Init_api_jump_tag(void) {
    mApiJump = rb_define_module("ApiJump");
    rb_define_module_function(mApiJump, "rethrow", api_rethrow, 1);
}
