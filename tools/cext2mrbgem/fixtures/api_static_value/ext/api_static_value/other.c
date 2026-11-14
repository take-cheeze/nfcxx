#include <ruby.h>

static VALUE sv_dup(VALUE v) {
    return v;
}

VALUE sv_other(VALUE v) {
    return sv_dup(v);
}
