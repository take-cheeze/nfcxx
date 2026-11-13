#include <ruby.h>

/* Numeric, symbol, constant, block and type-test calls with exact mruby equivalents (api_map.json, batch B2). */
static VALUE mNumSym;
static VALUE cNumSymBase;

static VALUE ns_dbl(VALUE self, VALUE x) {
    double d = NUM2DBL(x);
    VALUE f = DBL2NUM(d * 2.0);
    VALUE u = ULONG2NUM(3);
    return f;
}

static VALUE ns_sym(VALUE self, VALUE name) {
    ID id = rb_to_id(name);
    const char *cstr = rb_id2name(id);
    VALUE str = rb_id2str(id);
    if (SYMBOL_P(name)) return str;
    rb_raise(rb_eStandardError, "not a symbol");
    return Qnil;
}

static VALUE ns_const(VALUE self, VALUE name) {
    ID id = rb_to_id(name);
    if (rb_const_defined(cNumSymBase, id)) return Qtrue;
    if (rb_const_defined_at(mNumSym, id)) return Qtrue;
    return Qfalse;
}

static VALUE ns_block(VALUE self) {
    if (rb_block_given_p()) return Qtrue;
    return Qfalse;
}

static VALUE ns_type(VALUE self, VALUE obj) {
    if (RB_TYPE_P(obj, T_STRING)) return Qtrue;
    if (RB_LIKELY(RB_TYPE_P(obj, T_ARRAY))) return Qtrue;
    if (RB_UNLIKELY(NIL_P(obj))) return Qfalse;
    return Qnil;
}

void Init_api_num_sym_ctl(void) {
    mNumSym = rb_define_module("NumSym");
    cNumSymBase = rb_define_class("NumSymBase", rb_cObject);
    rb_define_module_function(mNumSym, "dbl", ns_dbl, 1);
    rb_define_module_function(mNumSym, "sym", ns_sym, 1);
    rb_define_module_function(mNumSym, "const", ns_const, 1);
    rb_define_module_function(mNumSym, "block", ns_block, 0);
    rb_define_module_function(mNumSym, "type", ns_type, 1);
}
