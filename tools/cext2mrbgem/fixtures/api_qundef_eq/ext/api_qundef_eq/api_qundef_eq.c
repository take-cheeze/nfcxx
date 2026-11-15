#include <ruby.h>
static VALUE mQe;

static VALUE qe_pick(VALUE self, VALUE opts) {
    VALUE mode = rb_hash_lookup2(opts, ID2SYM(rb_intern("half")), Qundef);
    if (mode == Qundef || NIL_P(mode))
        return Qfalse;
    if (mode != Qtrue)
        return Qnil;
    return mode;
}

void Init_api_qundef_eq(void) {
    mQe = rb_define_module("QundefEq");
    rb_define_module_function(mQe, "pick", qe_pick, 1);
}
