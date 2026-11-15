#include <ruby.h>
struct holder { VALUE a; VALUE b; };
static VALUE mMarkHelper;
static VALUE cHolder;
static void mk_helper(struct holder *h) {
    rb_gc_mark(h->a);
    rb_gc_mark_movable(h->b);
}
static void mk_mark(void *p) {
    mk_helper((struct holder *)p);
}
static void mk_free(void *p) { xfree(p); }
static const rb_data_type_t mk_type = { "mk", { mk_mark, mk_free, 0 }, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY };
static VALUE mk_new(VALUE self) {
    struct holder *h;
    VALUE obj = TypedData_Make_Struct(cHolder, struct holder, &mk_type, h);
    h->a = Qnil; h->b = Qnil;
    return obj;
}
void Init_api_mark_helper(void) {
    mMarkHelper = rb_define_module("MarkHelper");
    cHolder = rb_define_class_under(mMarkHelper, "Holder", rb_cObject);
    rb_define_module_function(mMarkHelper, "make", mk_new, 0);
}
