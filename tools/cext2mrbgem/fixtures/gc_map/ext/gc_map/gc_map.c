#include <ruby.h>

/* GC calls with an exact mruby equivalent: rb_gc_register_mark_object (mrb_gc_register, in Init),
 * rb_gc_start as a statement (mrb_full_gc), and rb_gc_writebarrier on plain locals (write barrier). */
static VALUE mGcMap;
static VALUE gcm_cache;
static VALUE gcm_slot;

static VALUE gcm_store(VALUE self, VALUE v) {
    gcm_slot = v;
    rb_gc_writebarrier(self, v);
    return Qnil;
}

static VALUE gcm_collect(VALUE self, VALUE force) {
    if (RTEST(force)) rb_gc_start();
    rb_gc_start();
    return gcm_cache;
}

void Init_gc_map(void) {
    mGcMap = rb_define_module("GcMap");
    gcm_cache = rb_str_new_cstr("kept");
    rb_gc_register_mark_object(gcm_cache);
    rb_define_module_function(mGcMap, "store", gcm_store, 1);
    rb_define_module_function(mGcMap, "collect", gcm_collect, 1);
}
