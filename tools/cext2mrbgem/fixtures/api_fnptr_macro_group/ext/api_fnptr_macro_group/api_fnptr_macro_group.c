#include <ruby.h>

/* two fields called through one macro body: field b is stored from a helper that is not defined here, so b is not threaded;
   field a (whose helper needs the state) must then keep its type too, because the macro body is shared and not edited */
struct mg_funcs {
    int (*a)(void *dat);
    int (*b)(void *dat);
};

struct mg {
    void *dat;
    const struct mg_funcs *funcs;
};

#define mg_attr(x) (mg->funcs->x)(mg->dat)
#define mg_a mg_attr(a)

extern int mg_external(void *dat);

static int mg_m_a(void *dat) {
    VALUE a = rb_ary_new();
    rb_ary_push(a, Qnil);
    return 1;
}

static const struct mg_funcs mg_funcs = {
    (int (*)(void *))mg_m_a,
    (int (*)(void *))mg_external,
};

static VALUE mg_run(VALUE self) {
    struct mg mg_v;
    struct mg *mg = &mg_v;
    mg_v.dat = (void *)self;
    mg_v.funcs = &mg_funcs;
    return INT2FIX(mg_a + mg_attr(b));
}

void Init_api_fnptr_macro_group(void) {
    VALUE m = rb_define_module("FnMacroGroup");
    rb_define_module_function(m, "run", mg_run, 0);
}
