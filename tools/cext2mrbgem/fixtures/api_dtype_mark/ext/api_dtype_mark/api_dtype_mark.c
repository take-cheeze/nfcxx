#include <ruby.h>

/* a name pasted by a local macro (DEF_LIMIT declares LIMIT_NAME_LENGTH) is not a CRuby name */
#define DEF_LIMIT(N, len) static const size_t LIMIT_##N##_LENGTH = (len)
#define CHECK_LIMIT(v, N) ((v) <= LIMIT_##N##_LENGTH)
DEF_LIMIT(NAME, 64);

typedef struct { VALUE held; } holder;

/* the mark callback of the data type: it marks the value it holds */
static void holder_mark(void *ptr) {
    holder *h = ptr;
    rb_gc_mark(h->held);
}

static const rb_data_type_t holder_type = {
    "holder",
    { holder_mark, RUBY_TYPED_DEFAULT_FREE, NULL },
    0, 0, 0,
};

static VALUE m_fits(VALUE self, VALUE n) {
    return CHECK_LIMIT(FIX2INT(n), NAME) ? Qtrue : Qfalse;
}

void Init_api_dtype_mark(void) {
    VALUE c = rb_define_class("DtypeMark", rb_cObject);
    rb_define_method(c, "fits", m_fits, 1);
}
