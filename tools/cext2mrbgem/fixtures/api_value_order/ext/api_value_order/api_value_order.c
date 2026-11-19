#include <ruby.h>

/* a sorted table of class VALUEs, built and searched with VALUE ordering (CRuby orders VALUEs by address) */
static VALUE table[8];
static int tlen = 0;

static int
vo_before(VALUE a, VALUE b)
{
    return a < b;
}

static VALUE
vo_add(VALUE self, VALUE v)
{
    int i = tlen;
    if (tlen >= 8) return Qfalse;
    while (i > 0 && vo_before(v, table[i - 1])) {
        table[i] = table[i - 1];
        i--;
    }
    table[i] = v;
    tlen++;
    return Qtrue;
}

void
Init_api_value_order(void)
{
    VALUE m = rb_define_module("ValueOrder");
    rb_define_module_function(m, "add", vo_add, 1);
}
