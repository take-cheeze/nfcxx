#include <ruby.h>

/* a flattened parent: fl_child's parent is fl_base (the fork has no parent field). A check against fl_base accepts a fl_child
 * object (CRuby's kind-of semantics), and a check against fl_child stays exact. */
typedef struct { int v; } fl_box;

static void fl_free(void *p) {
    xfree(p);
}

static const rb_data_type_t fl_base = {
  .wrap_struct_name = "FlBase",
  .function = { .dfree = fl_free },
  .flags = 0
};

static const rb_data_type_t fl_child = {
  .wrap_struct_name = "FlChild",
  .function = { .dfree = fl_free },
  .parent = &fl_base,
  .flags = 0
};

static VALUE fl_get(VALUE self, VALUE obj) {
    fl_box *b;
    (void)self;
    b = rb_check_typeddata(obj, &fl_base);
    (void)b;
    return rb_typeddata_is_kind_of(obj, &fl_child) ? Qtrue : Qfalse;
}

void Init_api_dtype_flat(void) {
    VALUE m = rb_define_module("FlMod");
    rb_define_module_function(m, "get", fl_get, 1);
    (void)fl_child;
}
