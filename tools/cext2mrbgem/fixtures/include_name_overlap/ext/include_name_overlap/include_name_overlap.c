#include <ruby.h>
#include <ruby/encoding.h>

/* The method name encoding is also the name of the header ruby/encoding.h. The identifier in the include path is not a
 * use of the function, and its refusal marker must not overlap the header rewrite (used to raise "overlapping edits"). */
static VALUE encoding(VALUE self) {
    return Qnil;
}

void Init_include_name_overlap(void) {
    VALUE cIncludeNameOverlap = rb_define_class("IncludeNameOverlap", rb_cObject);
    rb_define_method(cIncludeNameOverlap, "encoding", encoding, 0);
}
