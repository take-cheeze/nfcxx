#include <ruby.h>

/* A registered method called directly from two call sites. The method is split: its body makes a String, so its impl takes
   the mruby state, and the caller rd_sum (a registered method) has it in scope. The method's name is also a parameter of a
   prototype, a local of a nested block (in scope there only), and the target of an assignment: those uses are variables,
   not calls, so they do not refuse the method. */
static VALUE rd_tally(VALUE self, VALUE x) {
    return rb_str_new_cstr("tally");
}

static VALUE rd_helper(VALUE self, VALUE rd_tally);

static VALUE rd_helper(VALUE self, VALUE rd_tally) {
    return rd_tally;
}

static VALUE rd_sum(VALUE self) {
    VALUE a = rd_tally(self, self);
    {
        VALUE rd_tally = Qnil;
        a = rd_tally;
    }
    VALUE b = rd_tally(self, a);
    return rd_helper(self, b);
}

void Init_reg_direct(void) {
    VALUE mRegDirect = rb_define_module("RegDirect");
    rb_define_method(mRegDirect, "tally", rd_tally, 1);
    rb_define_method(mRegDirect, "sum", rd_sum, 0);
}
