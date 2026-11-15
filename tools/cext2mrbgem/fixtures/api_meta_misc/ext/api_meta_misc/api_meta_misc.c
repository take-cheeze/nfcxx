#include <ruby.h>
static const rb_data_type_t mm_type = { "m3", { 0, 0, 0 }, 0, 0, 0 };
static VALUE mMetaMisc;
static VALUE mm_run(VALUE self, VALUE obj, VALUE cls, VALUE argv_v) {
    void *p = rb_check_typeddata(obj, &mm_type);
    VALUE pw = rb_int_positive_pow(2, 10);
    VALUE mem = rb_struct_s_members(cls);
    VALUE argv[1];
    argv[0] = argv_v;
    rb_obj_call_init(obj, 1, argv);
    (void)p; (void)pw;
    return mem;
}
void Init_api_meta_misc(void) {
    mMetaMisc = rb_define_module("MetaMisc");
    rb_define_module_function(mMetaMisc, "run", mm_run, 3);
}
