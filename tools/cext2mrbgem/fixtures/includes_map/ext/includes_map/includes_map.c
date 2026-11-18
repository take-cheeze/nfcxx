#include <ruby/ruby.h>
#include <ruby/re.h>
#include <ruby/encoding.h>

/* ruby/ruby.h, ruby/re.h and ruby/encoding.h are mapped by api_map.json ("includes") to their mruby headers. */
static VALUE im_hello(VALUE self) {
    return rb_str_new_cstr("hi");
}

void Init_includes_map(void) {
    VALUE mIM = rb_define_module("IncludesMap");
    rb_define_method(mIM, "hello", im_hello, 0);
}
