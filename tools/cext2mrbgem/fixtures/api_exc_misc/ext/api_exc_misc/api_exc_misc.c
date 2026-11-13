#include <ruby.h>

/* Exception class, warning and GC-location uses with an exact mruby equivalent (api_map.json, batch C3). */
static VALUE mApiExc;

static VALUE api_boom(VALUE self, VALUE msg) {
    rb_warning("boom check: %s", "start");
    rb_raise(rb_eNoMemError, "out of room");
    return Qnil;
}

static VALUE api_moved(VALUE self, VALUE obj) {
    VALUE now = rb_gc_location(obj);
    return now;
}

void Init_api_exc_misc(void) {
    mApiExc = rb_define_module("ApiExc");
    rb_define_module_function(mApiExc, "boom", api_boom, 1);
    rb_define_module_function(mApiExc, "moved", api_moved, 1);
}
