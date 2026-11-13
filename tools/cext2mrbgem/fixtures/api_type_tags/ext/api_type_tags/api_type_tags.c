#include <ruby.h>

/* T_TRUE, RUBY_T_STRING, RUBY_T_SYMBOL, T_FALSE and RUBY_T_FIXNUM as type tags (api_map.json, batch D2). */
static VALUE mApiTag;

static VALUE api_is_true(VALUE self, VALUE v) {
    return RB_TYPE_P(v, T_TRUE) ? Qtrue : Qfalse;
}

static VALUE api_is_string(VALUE self, VALUE v) {
    return RB_TYPE_P(v, RUBY_T_STRING) ? Qtrue : Qfalse;
}

static VALUE api_tags(VALUE self, VALUE v) {
    int sym_tag = RUBY_T_SYMBOL;
    int str_tag = RUBY_T_STRING;
    int fix_tag = RUBY_T_FIXNUM;
    int false_tag = T_FALSE;
    if (sym_tag == str_tag || fix_tag == false_tag) return Qnil;
    return self;
}

void Init_api_type_tags(void) {
    mApiTag = rb_define_module("ApiTag");
    rb_define_module_function(mApiTag, "true?", api_is_true, 1);
    rb_define_module_function(mApiTag, "string?", api_is_string, 1);
    rb_define_module_function(mApiTag, "tags", api_tags, 1);
}
