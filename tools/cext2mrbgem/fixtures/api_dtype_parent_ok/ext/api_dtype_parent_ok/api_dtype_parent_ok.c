#include <ruby.h>

/* a data type whose parent is another rb_data_type_t of the input (declared earlier in the file): the parent converts to
 * .parent = &pc_base, which the fork's mrb_data_type has (mrb_data_type.parent) */
typedef struct { VALUE held; } pc_box;

static void pc_mark(void *p) {
    rb_gc_mark(((pc_box *)p)->held);
}

static void pc_free(void *p) {
    xfree(p);
}

static const rb_data_type_t pc_base = { "PcBase", { 0, 0, 0 }, 0, 0, 0 };

static const rb_data_type_t pc_child = {
  .wrap_struct_name = "PcChild",
  .function = { .dmark = pc_mark, .dfree = pc_free },
  .parent = &pc_base,
  .flags = 0
};

void Init_api_dtype_parent_ok(void) {
    (void)pc_child;
}
