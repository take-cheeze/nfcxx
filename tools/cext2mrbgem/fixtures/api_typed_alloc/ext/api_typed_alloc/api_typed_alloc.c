#include <ruby.h>

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

static VALUE mProbe;

static VALUE probe_new(VALUE self, VALUE v) {
    holder *h;
    VALUE obj = TypedData_Make_Struct(mProbe, holder, &holder_type, h);
    h->held = v;
    return obj;
}

void Init_api_typed_alloc(void) {
    mProbe = rb_define_module("ApiTypedAlloc");
    rb_define_module_function(mProbe, "make", probe_new, 1);
}
