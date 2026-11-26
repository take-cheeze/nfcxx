#include <ruby.h>

/* a data type with a parent is refused (mruby's mrb_data_type has no parent); its initializer is stubbed with the name kept,
 * so the compile check does not fail once per member */
typedef struct { VALUE held; } pa_box;

static void pa_mark(void *p) {
    rb_gc_mark(((pa_box *)p)->held);
}

static void pa_free(void *p) {
    xfree(p);
}

static const rb_data_type_t pa_base = { "PaBase", { 0, 0, 0 }, 0, 0, 0 };

static const rb_data_type_t pa_child = {
  .wrap_struct_name = "PaChild",
  .function = { .dmark = pa_mark, .dfree = pa_free },
  .parent = &pa_base,
  .flags = 0
};

void Init_api_dtype_parent(void) {
    (void)pa_child;
}
