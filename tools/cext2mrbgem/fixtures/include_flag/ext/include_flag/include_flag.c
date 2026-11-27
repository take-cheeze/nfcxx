#include <ruby.h>
#include "../hdr_flag.h"

/* "../hdr_flag.h" is one level above this extension directory. Run with --header ../hdr_flag.h, the converter reads that header
 * (and only that one) into the output at its include path: the include is kept and resolves. Without the flag it is refused. */

static VALUE inc_flag_one(VALUE self) {
    return hdr_flag_value();
}

void Init_include_flag(void) {
    VALUE mInc = rb_define_module("IncludeFlag");
    rb_define_module_function(mInc, "one", inc_flag_one, 0);
}
