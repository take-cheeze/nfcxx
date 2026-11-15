#include <ruby.h>
typedef struct _out { int depth; char *cur; } *Out;
static VALUE mIvarOutcast;
static int io_cb(ID key, VALUE value, VALUE ov) {
    Out out = (Out)ov;
    if (rb_id2name(key)[0] == '@') out->depth++;
    return ST_CONTINUE;
}
static void io_attrs(VALUE obj, int depth, Out out) {
    out->depth = depth + 1;
    rb_ivar_foreach(obj, io_cb, (VALUE)out);
}
static VALUE io_run(VALUE self, VALUE obj) {
    struct _out o;
    o.depth = 0;
    o.cur = 0;
    io_attrs(obj, 0, &o);
    return INT2FIX(o.depth);
}
void Init_api_ivar_outcast(void) {
    mIvarOutcast = rb_define_module("IvarOutcast");
    rb_define_module_function(mIvarOutcast, "run", io_run, 1);
}
