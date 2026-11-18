#include <ruby.h>

/* a gem-local name that a system header may also declare (renamed by --rename), with a signature the header disagrees on
   (retyped by --replace: the data argument is void * in the header) */
static char *
crypt_r(const char *key, const char *setting, struct crypt_data *data)
{
    return (char *)key;
}

static VALUE
m_hash(VALUE self, VALUE s)
{
    return rb_str_new_cstr(crypt_r(RSTRING_PTR(s), "", 0));
}

void
Init_api_rename_replace(void)
{
    VALUE c = rb_define_class("RenameReplace", rb_cObject);
    rb_define_method(c, "hash_it", m_hash, 1);
}
