#include <ruby.h>
#include <stdlib.h>
struct Blob { char *data; long len; };
static VALUE blob_free(VALUE mem);
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

void
Init_api_ensure_member(void)
{
    VALUE m = rb_define_module("EnsureMember");
    rb_define_module_function(m, "call", m_blob, 1);
}
