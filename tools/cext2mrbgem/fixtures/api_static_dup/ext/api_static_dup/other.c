#include <ruby.h>

/* the same static name, in a second file: a different function */
static int sd_check(VALUE v) {
    return RTEST(v) ? 1 : 0;
}

int sd_other(VALUE v) {
    return sd_check(v);
}
