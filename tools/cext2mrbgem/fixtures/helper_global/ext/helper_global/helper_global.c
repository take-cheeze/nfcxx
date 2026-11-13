#include <ruby.h>

/* hg_make calls the mruby state's API (rb_str_new) and has no mrb argument. Its only uses are direct calls through the
 * macro HG_MAKE, expanded in two registered methods, so it is not threaded: it uses the file-scope state that the
 * method sets on entry (no refusal). hg_pick has two returns, and its method restores the previous state on each. */
static VALUE hg_make(VALUE s) {
    return rb_str_new_cstr("made");
}

#define HG_MAKE(x) hg_make(x)

static VALUE hg_wrap(VALUE self, VALUE s) {
    return HG_MAKE(s);
}

static VALUE hg_pick(VALUE self, VALUE s) {
    if (NIL_P(s)) {
        return rb_str_new_cstr("nil");
    }
    return HG_MAKE(s);
}

void Init_helper_global(void) {
    VALUE m = rb_define_module("HelperGlobal");
    rb_define_module_function(m, "wrap", hg_wrap, 1);
    rb_define_module_function(m, "pick", hg_pick, 1);
}
