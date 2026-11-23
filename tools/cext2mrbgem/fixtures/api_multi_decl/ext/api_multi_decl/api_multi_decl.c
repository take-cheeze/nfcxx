#include <ruby.h>

/* an integer array declared after another declarator (st_index_t v, h[2];), assigned a VALUE-returning call: the word has no
   integer form in the fork, so it is a refusal (not a silent compile error) */
static VALUE
md_get(VALUE v)
{
    return v;
}

static VALUE
md_hash(VALUE self, VALUE v)
{
    st_index_t n, h[2];
    n = 0;
    h[0] = n;
    h[1] = md_get(v);
    return LONG2NUM((long)h[1]);
}

void
Init_api_multi_decl(void)
{
    VALUE m = rb_define_module("MultiDecl");
    rb_define_module_function(m, "hash_of", md_hash, 1);
}
