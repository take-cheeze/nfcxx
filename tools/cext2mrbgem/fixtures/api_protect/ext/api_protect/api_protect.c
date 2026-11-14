#include <ruby.h>

/* rb_protect with a callback that needs the mruby state (api_map.json batch P1): mrb_protect takes mrb_func_t,
 * so the callback is threaded with an mrb argument and passed as the body. */
static VALUE mApiProt;

static VALUE protect_body(VALUE arg) {
    return rb_str_new_cstr("ok");
}

static VALUE api_try(VALUE self) {
    int state = 0;
    VALUE r = rb_protect(protect_body, Qnil, &state);
    return r;
}

void Init_api_protect(void) {
    mApiProt = rb_define_module("ApiProt");
    rb_define_module_function(mApiProt, "try", api_try, 0);
}
