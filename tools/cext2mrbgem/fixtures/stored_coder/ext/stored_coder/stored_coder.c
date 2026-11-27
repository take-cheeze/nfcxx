#include <ruby.h>

/* A coder callback: its address is stored by pg_define_coder (a function of this input, which keeps the pointer in a table for
 * the life of the gem). The coder runs from Coder.run, a registered method, so the global state is set when it runs. */
typedef VALUE (*sc_fn_t)(VALUE);
typedef struct { const char *name; void *func; } sc_coder_t;
static sc_coder_t sc_coders[4];
static int sc_ncoders;

static void
pg_define_coder(const char *name, void *func)
{
    sc_coders[sc_ncoders].name = name;
    sc_coders[sc_ncoders].func = func;
    sc_ncoders++;
}

static VALUE
sc_enc(VALUE v)
{
    return rb_str_new_cstr("encoded");
}

static VALUE
sc_run(VALUE self, VALUE v)
{
    return ((sc_fn_t)sc_coders[0].func)(v);
}

void
Init_stored_coder(void)
{
    VALUE m = rb_define_module("StoredCoder");
    pg_define_coder("Enc", sc_enc);
    rb_define_module_function(m, "run", sc_run, 1);
}
