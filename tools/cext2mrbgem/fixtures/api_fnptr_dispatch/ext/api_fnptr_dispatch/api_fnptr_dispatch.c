#include <ruby.h>

/* a callback field called from a function whose address is taken in a dispatch table (fd_table): that function keeps
   its C signature, so the field takes no mruby state, and the callback stored in the field does not either */
struct fd_sink {
    void (*emit)(struct fd_sink *s, VALUE v);
    VALUE held;
};

typedef size_t (*fd_trigger)(struct fd_sink *s, size_t n);

static void fd_store(struct fd_sink *s, VALUE v) {
    rb_ary_push(s->held, v);
}

static size_t fd_run_one(struct fd_sink *s, size_t n) {
    s->emit(s, INT2FIX((int)n));
    return n + 1;
}

static fd_trigger fd_table[] = { &fd_run_one };

static VALUE fd_go(VALUE self, VALUE v) {
    struct fd_sink s;
    s.held = rb_ary_new();
    s.emit = fd_store;
    fd_table[0](&s, 1);
    return s.held;
}

void Init_api_fnptr_dispatch(void) {
    VALUE m = rb_define_module("FD");
    rb_define_module_function(m, "go", fd_go, 1);
}
