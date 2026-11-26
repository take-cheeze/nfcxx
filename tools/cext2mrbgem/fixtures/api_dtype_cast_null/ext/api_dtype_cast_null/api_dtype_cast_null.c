#include <ruby.h>

/* a data type whose mark function is written as a cast of NULL, (RUBY_DATA_FUNC) NULL, and whose free is
   RUBY_TYPED_DEFAULT_FREE (pg's coder types): both are null functions, so the type converts with no refusal */
struct cast_null_box {
    VALUE held;
};

static size_t cast_null_size(const void *p) {
    (void)p;
    return sizeof(struct cast_null_box);
}

static const rb_data_type_t cast_null_type = {
    "CastNullBox",
    {
        (RUBY_DATA_FUNC) NULL,
        RUBY_TYPED_DEFAULT_FREE,
        cast_null_size,
    },
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE cast_null_new(VALUE self) {
    struct cast_null_box *b;
    VALUE obj = TypedData_Make_Struct(self, struct cast_null_box, &cast_null_type, b);
    b->held = Qnil;
    return obj;
}

void Init_api_dtype_cast_null(void) {
    VALUE m = rb_define_module("DTCN");
    rb_define_module_function(m, "make", cast_null_new, 0);
}
