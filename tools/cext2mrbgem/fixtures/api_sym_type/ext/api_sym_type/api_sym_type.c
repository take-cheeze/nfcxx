#include <ruby.h>

/* Symbol id and integer type-tag uses with an exact mruby equivalent (api_map.json, batch C2). */
static VALUE mApiSym;

static VALUE api_sym_roundtrip(VALUE self, VALUE sym) {
    ID id = SYM2ID(sym);
    return ID2SYM(id);
}

static VALUE api_is_fixnum(VALUE self, VALUE v) {
    if (rb_type(v) == T_FIXNUM) return Qtrue;
    return Qfalse;
}

void Init_api_sym_type(void) {
    mApiSym = rb_define_module("ApiSym");
    rb_define_module_function(mApiSym, "roundtrip", api_sym_roundtrip, 1);
    rb_define_module_function(mApiSym, "fixnum_p", api_is_fixnum, 1);
}
