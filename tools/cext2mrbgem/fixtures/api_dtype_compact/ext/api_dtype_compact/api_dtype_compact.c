#include <ruby.h>

/* a compaction member written as a macro call (ffi's compat.h) is dropped: mruby never compacts (the positional form drops
 * dcompact too). The callbacks take the mruby state through their bodies, as in api_dtype. */
#define cm_compact_callback(x) .dcompact = (x),

typedef struct { VALUE held; } cm_box;

static void cm_mark(void *p) {
    rb_gc_mark(((cm_box *)p)->held);
}

static void cm_free(void *p) {
    xfree(p);
}

static void cm_compact(void *p) {
    (void)p;
}

static size_t cm_size(const void *p) {
    (void)p;
    return 0;
}

static const rb_data_type_t cm_type = {
  .wrap_struct_name = "CmBox",
  .function = {
    .dmark = cm_mark,
    .dfree = cm_free,
    .dsize = cm_size,
    cm_compact_callback( cm_compact )
  },
  .parent = 0,
  .data = 0,
  .flags = 0
};

void Init_api_dtype_compact(void) {
    (void)cm_type;
}
