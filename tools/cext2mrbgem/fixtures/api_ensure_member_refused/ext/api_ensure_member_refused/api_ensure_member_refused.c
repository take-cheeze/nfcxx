#include <ruby.h>
#include <stdlib.h>
struct Blob { char *data; long len; };
/* the body reads the blob the struct holds; the ensure callback frees the pointer carried in the data argument */
static VALUE
blob_body(VALUE v)
{
    struct Blob *b = (struct Blob *)v;
    return rb_str_new(b->data, b->len);
}

static VALUE
blob_free(VALUE mem)
{
    free((void *)mem);
    return Qfalse;
}

static VALUE
m_blob(VALUE self, VALUE len)
{
    struct Blob b;
    b.data = malloc(8);
    b.len = 8;
    return rb_ensure(blob_body, (VALUE)&b, blob_free, (VALUE)b.data);
}

static VALUE (*kept_free)(VALUE);
void
Init_api_ensure_member_refused(void)
{
    kept_free = blob_free;
    VALUE m = rb_define_module("EnsureMemberRefused");
    rb_define_module_function(m, "call", m_blob, 1);
}
