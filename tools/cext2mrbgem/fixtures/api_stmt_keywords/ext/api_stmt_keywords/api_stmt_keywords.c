#include <ruby.h>

/* "else if (c) {" is a statement, not a definition: the braceless loop and its yield are converted, not dead code. */
static VALUE
m_loop(int argc, VALUE *argv, VALUE self)
{
    int c = argc;
    if (c < 0) {
	return Qnil;
    }
    else if (c == 0) {
	while (1)
	    rb_yield(self);
    }
    return Qnil;
}

/* SYM2ID of a Symbol value: the method name is that symbol (mrb_symbol). */
static VALUE
m_send_sym(VALUE self, VALUE sym)
{
    return rb_funcall(self, SYM2ID(sym), 0);
}

/* rb_cmpint: the sign of a <=> result. */
static VALUE
m_cmp(VALUE self, VALUE other)
{
    return INT2FIX(rb_cmpint(rb_funcall(self, rb_intern("<=>"), 1, other), self, other));
}

void
Init_api_stmt_keywords(void)
{
    VALUE c = rb_define_class("StmtKw", rb_cObject);
    rb_define_method(c, "loop_it", m_loop, -1);
    rb_define_method(c, "send_sym", m_send_sym, 1);
    rb_define_method(c, "cmp", m_cmp, 1);
}
