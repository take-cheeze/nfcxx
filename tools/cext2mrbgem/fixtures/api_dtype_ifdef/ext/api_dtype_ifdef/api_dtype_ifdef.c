#include <ruby.h>

struct dt_box { int n; };

static void dt_mark(void *p) { (void)p; }
static void dt_free(void *p) { xfree(p); }
static size_t dt_size(const void *p) { (void)p; return sizeof(struct dt_box); }
#ifdef HAVE_RB_GC_MARK_MOVABLE
static void dt_compact(void *p) { (void)p; }
#endif

static const rb_data_type_t dt_type = {
    "DtBox",
    {
        dt_mark,
        dt_free,
        dt_size,
#ifdef HAVE_RB_GC_MARK_MOVABLE
        dt_compact,
#endif
    },
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE mDt;

void Init_api_dtype_ifdef(void) {
    mDt = rb_define_module("DtIfdef");
    (void)dt_type;
}
