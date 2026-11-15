#include <ruby.h>
#include "tf_other.h"
static VALUE mTf;

#define tf_neg(x) rb_funcall(x, rb_intern("-@"), 0)

static VALUE tf_run(VALUE self, VALUE v) {
    return tf_neg(v);
}

void Init_api_macro_twofile(void) {
    mTf = rb_define_module("MacroTwofile");
    rb_define_module_function(mTf, "run", tf_run, 1);
    tf_other_setup(mTf);
}
