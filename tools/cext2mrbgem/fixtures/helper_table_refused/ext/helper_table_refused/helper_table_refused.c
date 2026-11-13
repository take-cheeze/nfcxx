#include <ruby.h>

static VALUE mHTR;

/* a helper whose address is stored in a static table: the table is read by code that has no method context, so the
   helper must not take mrb (its uses are not all direct calls) and must stay refused */
static VALUE htr_cb(VALUE s) {
    return rb_str_new_cstr("cb");
}

struct htr_entry { const char *name; VALUE (*fn)(VALUE); };
static struct htr_entry htr_table[] = { { "cb", htr_cb } };

static VALUE htr_run(VALUE self, VALUE s) {
    return htr_cb(s);
}

void Init_helper_table_refused(void) {
    mHTR = rb_define_module("HelperTableRefused");
    rb_define_module_function(mHTR, "run", htr_run, 1);
}
