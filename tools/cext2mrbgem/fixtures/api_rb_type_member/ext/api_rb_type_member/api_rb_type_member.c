#include <ruby.h>
struct V { VALUE val; int odd; };
static VALUE f(struct V *parent) {
WHICH_TYPE:
    switch (rb_type(parent->val)) {
    case T_NIL:
        parent->odd = 0;
        return Qnil;
    case T_STRING:
        return rb_str_new_cstr("s");
    default:
        return Qfalse;
    }
}
void Init_api_rb_type_member(void) { }
