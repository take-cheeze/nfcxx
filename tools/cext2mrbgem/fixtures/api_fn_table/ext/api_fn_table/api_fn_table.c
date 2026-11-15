#include <ruby.h>
static VALUE mFt;

typedef struct { VALUE (*on_item)(VALUE v); } FtCallbacks;

static VALUE ft_item(VALUE v) {
    return rb_str_new_cstr("item");
}

static FtCallbacks ft_cbs = { ft_item };

static VALUE ft_each(VALUE self, VALUE v) {
    return ft_cbs.on_item(v);
}

void Init_api_fn_table(void) {
    mFt = rb_define_module("FnTable");
    rb_define_module_function(mFt, "each", ft_each, 1);
}
