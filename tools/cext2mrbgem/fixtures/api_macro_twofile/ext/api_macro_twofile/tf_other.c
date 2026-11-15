#include <ruby.h>
#include "tf_other.h"

/* the same macro name as the other file; its own use is in a function without the state: refused here, and only here */
#define tf_neg(x) rb_funcall(x, rb_intern("-@"), 0)

static VALUE tf_other_plain(VALUE self, VALUE x) {
    return tf_neg(x);
}

void tf_other_setup(VALUE m) {
    rb_define_module_function(m, "plain", tf_other_plain, 1);
}
