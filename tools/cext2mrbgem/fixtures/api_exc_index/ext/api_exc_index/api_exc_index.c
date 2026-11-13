#include <ruby.h>

/* rb_eIndexError and rb_eRangeError used as the class argument of rb_raise (api_map.json, batch D1). */
static VALUE mApiIdx;

static VALUE api_index(VALUE self, VALUE pos) {
    rb_raise(rb_eIndexError, "index out of range");
    return Qnil;
}

static VALUE api_range(VALUE self, VALUE len) {
    rb_raise(rb_eRangeError, "value out of range");
    return Qnil;
}

void Init_api_exc_index(void) {
    mApiIdx = rb_define_module("ApiIdx");
    rb_define_module_function(mApiIdx, "index", api_index, 1);
    rb_define_module_function(mApiIdx, "range", api_range, 1);
}
