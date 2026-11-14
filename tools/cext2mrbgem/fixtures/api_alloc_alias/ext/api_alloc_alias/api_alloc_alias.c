#include <ruby.h>
static VALUE mAl;
static VALUE aa_run(VALUE self, VALUE s, VALUE k) {
    char *buf = ALLOC_N(char, 16);
    VALUE h = rb_hash(s);
    VALUE sc = rb_singleton_class(s);
    VALUE n = rb_str_to_inum(s, 10, 0);
    long len = 0;
    char *p = 0;
    RSTRING_GETMEM(s, p, len);
    rb_gc();
    ID ia = rb_intern("a");
    ID ib = rb_intern("b");
    rb_alias(mAl, ia, ib);
    (void)buf; (void)sc;
    return n;
}
void Init_api_alloc_alias(void) {
    mAl = rb_define_module("AllocAlias");
    rb_define_module_function(mAl, "run", aa_run, 2);
}
