#include <ruby.h>
#include "../hdr.h"

/* the header "../hdr.h" is outside this extension directory: the converter reads only the extension root, so it is not in the
 * output, and the include is refused at conversion time (REFUSALS.txt), not left to the compile check */

static VALUE inc_outside_one(VALUE self) {
    return INT2FIX(1);
}

void Init_include_outside(void) {
    VALUE mInc = rb_define_module("IncludeOutside");
    rb_define_module_function(mInc, "one", inc_outside_one, 0);
}
