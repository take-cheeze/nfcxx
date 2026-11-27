#include <ruby.h>

/* The method's name is used as an address before a local of the same name is declared: that first use is the file-scope
   function (a local hides the name only from its declaration on), so its address is taken and the method keeps its
   refusal. The later uses of the local are variables. */
static VALUE rda_tally(VALUE self, VALUE x) {
    return rb_str_new_cstr("tally");
}

static VALUE rda_sum(VALUE self) {
    void *p = rda_tally;
    VALUE rda_tally = Qnil;
    return rda_tally;
}

void Init_reg_direct_addr(void) {
    VALUE mRegDirectAddr = rb_define_module("RegDirectAddr");
    rb_define_method(mRegDirectAddr, "tally", rda_tally, 1);
    rb_define_method(mRegDirectAddr, "sum", rda_sum, 0);
}
