#include <ruby.h>

/* Forms that have no exact mruby equivalent: rest, keyword, a used return value, and a call outside a variadic method. */
static VALUE mRef;

static VALUE ref_rest(int argc, VALUE *argv, VALUE self) {
    VALUE a;
    rb_scan_args(argc, argv, "*", &a);
    return a;
}

static VALUE ref_keyword(int argc, VALUE *argv, VALUE self) {
    VALUE a, kw;
    rb_scan_args(argc, argv, "1:", &a, &kw);
    return a;
}

static VALUE ref_used(int argc, VALUE *argv, VALUE self) {
    VALUE a;
    int n = rb_scan_args(argc, argv, "1", &a);
    (void)n;
    return a;
}

static VALUE fixed_arity(VALUE self, VALUE x) {
    VALUE a;
    rb_scan_args(1, &x, "1", &a);
    return a;
}

void Init_scan_args_refused(void) {
    mRef = rb_define_module("ScanRefused");
    rb_define_singleton_method(mRef, "rest", ref_rest, -1);
    rb_define_singleton_method(mRef, "keyword", ref_keyword, -1);
    rb_define_singleton_method(mRef, "used", ref_used, -1);
    rb_define_singleton_method(mRef, "fixed", fixed_arity, 1);
}
