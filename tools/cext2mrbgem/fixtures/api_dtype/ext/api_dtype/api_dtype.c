#include <ruby.h>

/* A data type with a mark and a free callback (api_map.json batch N10): the callbacks take the mruby state, and the
 * initializer is reordered to mruby's {name, dfree, mark}; rb_gc_mark is valid inside the mark callback */
typedef struct { VALUE held; } holder;

static void holder_mark(void *p) {
    rb_gc_mark(((holder *)p)->held);
}

static void holder_free(void *p) {
    xfree(p);
}

static const rb_data_type_t holder_type = {
    "holder",
    {holder_mark, holder_free, NULL},
    0, 0,
    RUBY_TYPED_FREE_IMMEDIATELY
};

void Init_api_dtype(void) {
    (void)holder_type;
}
