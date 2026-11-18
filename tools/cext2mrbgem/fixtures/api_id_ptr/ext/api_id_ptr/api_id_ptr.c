#include <ruby.h>
static ID attrs[4];
static void set_it(VALUE x, const char **np) {
    ID *idp;
    for (idp = attrs; 0 != *np; idp++, np++) {
        *idp = rb_intern(*np);
    }
    *idp = 0;
}
static VALUE m(VALUE self) { return Qnil; }
void Init_api_id_ptr(void) { rb_define_method(rb_cObject, "id_ptr_m", m, 0); }
