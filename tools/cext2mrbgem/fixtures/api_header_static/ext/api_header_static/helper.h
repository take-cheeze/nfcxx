#ifndef HS_HELPER_H
#define HS_HELPER_H
#include <ruby.h>
/* a static (not inline) helper in a header: local to each includer, so it may take the mruby state */
static int hs_check(VALUE v) {
    if (NIL_P(v)) rb_raise(rb_eArgError, "nil");
    return RTEST(v) ? 1 : 0;
}
#endif
