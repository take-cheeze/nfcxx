#include <ruby/ruby.h>
#include <ruby/re.h>
#include <ruby/encoding.h>

/* ruby/ruby.h and ruby/re.h are mapped by api_map.json ("includes"); ruby/encoding.h has no mruby counterpart. */
static VALUE im_hello(VALUE self) {
    return rb_str_new_cstr("hi");
}

void Init_includes_map(void) {
    VALUE mIM = rb_define_module("IncludesMap");
    rb_define_method(mIM, "hello", im_hello, 0);
}
