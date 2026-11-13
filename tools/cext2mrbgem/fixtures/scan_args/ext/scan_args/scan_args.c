#include <ruby.h>

/* rb_scan_args in variadic methods (argc -1): the forms with a lead and an optional count are mapped. */
static VALUE mScan;

static VALUE sa_opt(int argc, VALUE *argv, VALUE self) {
    VALUE first, second;
    rb_scan_args(argc, argv, "11", &first, &second);
    if (NIL_P(second)) return first;
    return second;
}

static VALUE sa_none(int argc, VALUE *argv, VALUE self) {
    rb_scan_args(argc, argv, "0");
    return Qnil;
}

static VALUE sa_mix(int argc, VALUE *argv, VALUE self) {
    VALUE a, b, c;
    rb_scan_args(argc, argv, "12", &a, &b, &c);
    return a;
}

void Init_scan_args(void) {
    mScan = rb_define_module("ScanArgs");
    rb_define_singleton_method(mScan, "opt", sa_opt, -1);
    rb_define_singleton_method(mScan, "none", sa_none, -1);
    rb_define_singleton_method(mScan, "mix", sa_mix, -1);
}
