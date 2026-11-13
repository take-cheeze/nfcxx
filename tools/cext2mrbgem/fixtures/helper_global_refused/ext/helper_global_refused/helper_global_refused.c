#include <ruby.h>

/* A helper whose address is stored in a file-scope static table: the table outlives every method, so the pointer may
 * be called with no method context. It stays refused. */
static VALUE hgr_cb(VALUE s) {
    return rb_str_new_cstr("cb");
}

static VALUE (*hgr_table[])(VALUE) = { hgr_cb };

static VALUE hgr_run(VALUE self, VALUE s) {
    return hgr_table[0](s);
}

void Init_helper_global_refused(void) {
    VALUE m = rb_define_module("HelperGlobalRefused");
    rb_define_module_function(m, "run", hgr_run, 1);
}
