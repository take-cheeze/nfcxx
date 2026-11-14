#include <ruby.h>
static const char *rb_fs_names[] = {"a", "b"};
static VALUE mFileScope;
static VALUE fs_run(VALUE self, VALUE v) {
    VALUE n = rb_to_int(v);
    if (rb_fs_names[0][0] == 'a') return n;
    return v;
}
void Init_api_file_scope(void) {
    mFileScope = rb_define_module("FileScope");
    rb_define_module_function(mFileScope, "run", fs_run, 1);
}
