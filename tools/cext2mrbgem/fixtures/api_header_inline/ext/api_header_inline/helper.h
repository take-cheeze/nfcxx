#include <ruby.h>

static inline int ahi_check(VALUE v) {
    if (NIL_P(v)) {
        rb_raise(rb_eArgError, "nil");
    }
    return 1;
}
