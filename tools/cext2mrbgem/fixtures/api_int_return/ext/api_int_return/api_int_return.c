#include <ruby.h>
static VALUE mProbe;
static int ir_cb(VALUE a, VALUE b) { return a == b; }
static int ir_sub(VALUE s, int (*cb)(VALUE, VALUE)) { return cb(s, s); }
#define IR_SUBS(s,c) \
do { \
    return ir_sub(s, c); \
} while (0)
static VALUE ir_run(VALUE self, VALUE s) {
    IR_SUBS(s, ir_cb);
}
void Init_api_int_return(void) {
    mProbe = rb_define_module("Probe");
    rb_define_module_function(mProbe, "run", ir_run, 1);
}
