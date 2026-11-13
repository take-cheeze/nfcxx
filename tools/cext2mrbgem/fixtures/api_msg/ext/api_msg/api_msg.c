#include <ruby.h>

/* rb_warn, rb_obj_classname, rb_sym2id and rb_sys_fail with an exact mruby equivalent (api_map.json, batch D4). */
static VALUE mApiMsg;

static VALUE api_say(VALUE self, VALUE obj) {
    const char *name = rb_obj_classname(obj);
    rb_warn("say: %s", name);
    return self;
}

static VALUE api_open(VALUE self, VALUE path) {
    ID id = rb_sym2id(path);
    if (id == 0) rb_sys_fail("open");
    return self;
}

void Init_api_msg(void) {
    mApiMsg = rb_define_module("ApiMsg");
    rb_define_module_function(mApiMsg, "say", api_say, 1);
    rb_define_module_function(mApiMsg, "open", api_open, 1);
}
