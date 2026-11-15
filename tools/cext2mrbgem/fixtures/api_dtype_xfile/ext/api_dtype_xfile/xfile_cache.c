#include <ruby.h>
#include "xfile_cache.h"

void xf_mark(void *data) {
    VALUE v = *(VALUE *)data;
    rb_gc_mark(v);
}

void xf_free(void *data) {
    xfree(data);
}

const rb_data_type_t xf_type = {
    "Xf",
    {xf_mark, xf_free, 0},
    0, 0,
};
