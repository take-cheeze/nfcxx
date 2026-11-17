#include <ruby.h>

struct cbs {
    void (*fn)(VALUE);
};

static struct cbs C;
static VALUE last = Qnil;

static void note(VALUE v)
{
    last = rb_str_dup(v);
}

static VALUE m_run(VALUE self, VALUE v)
{
    C.fn = note;
    C.fn(v);
    return last;
}

void Init_api_method_scope(void)
{
    rb_define_method(rb_cObject, "run_note", m_run, 1);
}
