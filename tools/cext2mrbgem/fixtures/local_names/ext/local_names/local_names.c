#include <ruby.h>

/* Macros and a struct tag the input defines: not CRuby APIs, so they are kept as they are (no refusal). */
#define LN_TWICE(x) ((x) * 2)
#define LN_ANSWER 42

struct rb_ln_state { long count; };

/* A local named like a CRuby variable (rb_cObject is a CRuby global): every use is inside this function. */
static VALUE ln_twice(VALUE self, VALUE v) {
    long n = NUM2LONG(v);
    VALUE rb_ln_out;
    rb_ln_out = LONG2NUM(LN_TWICE(n));
    return rb_ln_out;
}

static VALUE ln_answer(VALUE self) {
    return LONG2NUM(LN_ANSWER);
}

static VALUE ln_count(VALUE self) {
    struct rb_ln_state s;
    s.count = 4;
    return LONG2NUM(s.count);
}

void Init_local_names(void) {
    VALUE mLN = rb_define_module("LocalNames");
    rb_define_method(mLN, "twice", ln_twice, 1);
    rb_define_method(mLN, "answer", ln_answer, 0);
    rb_define_method(mLN, "count", ln_count, 0);
}
