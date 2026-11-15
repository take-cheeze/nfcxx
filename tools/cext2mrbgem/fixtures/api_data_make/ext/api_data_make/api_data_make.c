#include <ruby.h>
static VALUE mDm;

typedef struct { long count; } DmBox;

static void dm_mark(void *p) {
    (void)p;
}

static void dm_free(void *p) {
    xfree(p);
}

static VALUE dm_new(VALUE self, VALUE klass) {
    DmBox *box;
    VALUE obj = Data_Make_Struct(klass, DmBox, dm_mark, dm_free, box);
    box->count = 7;
    return obj;
}

void Init_api_data_make(void) {
    mDm = rb_define_module("DataMake");
    rb_define_module_function(mDm, "make", dm_new, 1);
}
