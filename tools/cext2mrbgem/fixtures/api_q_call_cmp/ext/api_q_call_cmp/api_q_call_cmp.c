#include <assert.h>
#include <ruby.h>

/* an ID-typed variable that holds a symbol VALUE (assigned ID2SYM), used as a hash key */
static ID sym_key;

/* a file-scope VALUE initialized to nil: not a constant in C, so it is set at the start of Init */
static VALUE saved_nil = Qnil;

static VALUE
m_key(VALUE self, VALUE h)
{
    return rb_hash_aref(h, sym_key);
}

/* a call compared with nil and false: identity in CRuby, a test of the value in mruby (the call is evaluated once) */
static VALUE
m_missing(VALUE self, VALUE h, VALUE k)
{
    if (rb_hash_aref(h, k) == Qnil) return Qtrue;
    if (rb_hash_aref(h, k) != Qfalse) return Qfalse;
    return Qnil;
}

/* a VALUE member: CRuby's Qfalse is the zero word, so 0 stored in it, or compared with it, is Qfalse */
struct qcc_holder { VALUE t; };

static VALUE
qcc_reset(struct qcc_holder *q)
{
    q->t = 0;
    return q->t != 0 ? Qtrue : Qfalse;
}

/* a method called by an ID held in a variable (an mrb_sym after conversion) */
static VALUE
m_call_id(VALUE self, VALUE target)
{
    ID mid = rb_intern("to_s");
    return rb_funcall(target, mid, 0);
}

void
Init_api_q_call_cmp(void)
{
    VALUE c = rb_define_class("QCallCmp", rb_cObject);
    rb_define_method(c, "missing", m_missing, 2);
    sym_key = ID2SYM(rb_intern("key"));
    saved_nil = Qnil;
    rb_define_method(c, "key", m_key, 1);
    rb_define_method(c, "call_id", m_call_id, 1);
}
