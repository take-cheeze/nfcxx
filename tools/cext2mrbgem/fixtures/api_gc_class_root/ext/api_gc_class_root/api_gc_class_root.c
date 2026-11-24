#include <ruby.h>

/* class variables registered as GC roots in Init: each class is a constant too, and its registration keeps it alive */
static VALUE cWidget;
static VALUE cGizmo;

void
Init_api_gc_class_root(void)
{
    cWidget = rb_define_class("Widget", rb_cObject);
    rb_gc_register_address(&cWidget);
    cGizmo = rb_define_class("Gizmo", rb_cObject);
    rb_global_variable(&cGizmo);
}
