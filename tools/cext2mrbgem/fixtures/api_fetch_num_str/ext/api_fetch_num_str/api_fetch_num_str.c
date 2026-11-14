#include <ruby.h>

/* rb_hash_lookup2, rb_str_buf_cat, rb_usascii_str_new*, rb_ll2inum, NUM2UINT, NUM2SIZET, FIX2ULONG and OBJ_FREEZE
 * (api_map.json, batch A1). */
static VALUE mApiFetch;

static VALUE api_lookup(VALUE self, VALUE h, VALUE k, VALUE dflt) {
    return rb_hash_lookup2(h, k, dflt);
}

static VALUE api_cat(VALUE self, VALUE dst, VALUE src) {
    rb_str_buf_cat(dst, RSTRING_PTR(src), RSTRING_LEN(src));
    return dst;
}

static VALUE api_ascii(VALUE self, VALUE src) {
    rb_usascii_str_new2("ok");
    rb_usascii_str_new_cstr("ok");
    return rb_usascii_str_new(RSTRING_PTR(src), RSTRING_LEN(src));
}

static VALUE api_wide(VALUE self, VALUE n) {
    long big = NUM2LONG(n);
    return rb_ll2inum(big);
}

static VALUE api_sizes(VALUE self, VALUE a, VALUE b) {
    unsigned int u = NUM2UINT(a);
    size_t s = NUM2SIZET(b);
    return INT2NUM((int)(u + s));
}

static VALUE api_fix(VALUE self, VALUE v) {
    unsigned long ul = FIX2ULONG(v);
    return ULONG2NUM(ul);
}

static VALUE api_freeze(VALUE self, VALUE str) {
    OBJ_FREEZE(str);
    return str;
}

void Init_api_fetch_num_str(void) {
    mApiFetch = rb_define_module("ApiFetch");
    rb_define_module_function(mApiFetch, "lookup", api_lookup, 3);
    rb_define_module_function(mApiFetch, "cat", api_cat, 2);
    rb_define_module_function(mApiFetch, "ascii", api_ascii, 1);
    rb_define_module_function(mApiFetch, "wide", api_wide, 1);
    rb_define_module_function(mApiFetch, "sizes", api_sizes, 2);
    rb_define_module_function(mApiFetch, "fix", api_fix, 1);
    rb_define_module_function(mApiFetch, "freeze", api_freeze, 1);
}
