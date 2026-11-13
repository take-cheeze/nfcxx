#include <ruby.h>

/* GC calls with no exact mruby equivalent, or used in a form the converter cannot map. Each must stay refused. */
static VALUE mGcMapRefused;
static VALUE gmr_addr;

static VALUE gmr_register_address(VALUE self) {
    rb_gc_register_address(&gmr_addr);
    return Qnil;
}

static VALUE gmr_global(VALUE self) {
    rb_global_variable(&gmr_addr);
    return Qnil;
}

static VALUE gmr_enable(VALUE self) {
    VALUE was = rb_gc_disable();
    rb_gc_enable();
    return was;
}

static VALUE gmr_start_value(VALUE self) {
    VALUE r = rb_gc_start();
    return r;
}

static void gmr_mark(void *p) {
    rb_gc_mark(*(VALUE *)p);
}

static VALUE gmr_wb_expr(VALUE self, VALUE v) {
    rb_gc_writebarrier(self, rb_str_new_cstr("x"));
    return v;
}

void Init_gc_map_refused(void) {
    mGcMapRefused = rb_define_module("GcMapRefused");
    rb_define_module_function(mGcMapRefused, "address", gmr_register_address, 0);
    rb_define_module_function(mGcMapRefused, "global", gmr_global, 0);
    rb_define_module_function(mGcMapRefused, "enable", gmr_enable, 0);
    rb_define_module_function(mGcMapRefused, "start_value", gmr_start_value, 0);
    rb_define_module_function(mGcMapRefused, "wb_expr", gmr_wb_expr, 1);
}
