#include <ruby.h>

/* a table of callbacks with a macro-wrapped call (date's tmx_funcs): the entries are casts of helpers that need the
   mruby state, and the call is made through the field in a macro expanded in a function with a state */
struct fct_funcs {
    int (*mday)(void *dat);
    VALUE (*secs)(void *dat);
};

struct fct {
    void *dat;
    const struct fct_funcs *funcs;
};

#define fct_attr(x) (fct->funcs->x)(fct->dat)
#define fct_mday fct_attr(mday)

static int fct_m_mday(void *dat) {
    VALUE a = rb_ary_new();
    rb_ary_push(a, Qnil);
    return 1;
}

static VALUE fct_m_secs(void *dat) {
    return rb_ary_new();
}

static const struct fct_funcs fct_funcs = {
    (int (*)(void *))fct_m_mday,
    (VALUE (*)(void *))fct_m_secs,
};

static void set_fct(VALUE self, struct fct *fct) {
    fct->dat = (void *)self;
    fct->funcs = &fct_funcs;
}

static VALUE fct_day(VALUE self) {
    struct fct fct_v;
    struct fct *fct = &fct_v;
    set_fct(self, fct);
    return INT2FIX(fct_mday);
}

void Init_api_fnptr_cast_table(void) {
    VALUE m = rb_define_module("FnCastTable");
    rb_define_module_function(m, "day", fct_day, 0);
}
