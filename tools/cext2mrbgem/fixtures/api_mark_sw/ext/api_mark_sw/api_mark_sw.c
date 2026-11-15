#include <ruby.h>

typedef struct { VALUE stream; int n; } SwBox;

static void sw_mark(void *ptr) {
    if (NULL != ptr) {
        SwBox *sw = (SwBox *)ptr;
        if (Qnil != sw->stream) {
            rb_gc_mark(sw->stream);
        }
    }
}

static void sw_free(void *ptr) {
    xfree(ptr);
}

static const rb_data_type_t sw_type = {
    "Sw/box",
    {
        sw_mark,
        sw_free,
        NULL,
    },
    0,
    0,
};

static VALUE mSw;

void Init_api_mark_sw(void) {
    mSw = rb_define_module("MarkSw");
    (void)sw_type;
}
