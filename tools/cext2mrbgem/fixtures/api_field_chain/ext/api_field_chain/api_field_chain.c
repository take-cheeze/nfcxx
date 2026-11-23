#include <ruby.h>

/* a field name declared VALUE in one struct and as a function pointer in another: an if on the VALUE member of a nested struct
   is a truth test of the VALUE, decided by the struct the chain reaches (not by the name) */
struct fc_opts {
    VALUE hook;
};

struct fc_holder {
    struct fc_opts options;
};

struct fc_other {
    void (*hook)(int);
};

static int
fc_has(struct fc_holder *h)
{
    if (h->options.hook)
        return 1;
    return 0;
}

void
Init_api_field_chain(void)
{
    rb_define_module("FieldChain");
}
