#include <ruby.h>

/* a table of callbacks of an anonymous struct type (ffi's MemoryOp): the callbacks are defined by a function-defining macro that
   pastes the names (memop_get_##name), and each one calls a state function (rb_ary_new), so it needs the mruby state. The table
   entries are positional initializers of the typedef's variables. A pointer's member is called through (*f->op->get)(...) and
   op->put(...), and both calls are in registered methods. */
typedef struct {
    VALUE (*get)(void *ptr, long offset);
    void (*put)(void *ptr, long offset, VALUE value);
} memop_ops;

struct memop_field {
    void *ptr;
    const memop_ops *op;
};

#define NUM_MEMOP(name, type) \
static VALUE memop_get_##name(void *ptr, long off) { type tmp = 0; (void)tmp; (void)ptr; (void)off; return rb_ary_new(); } \
static void memop_put_##name(void *ptr, long off, VALUE value) { (void)ptr; (void)off; rb_ary_push(value, Qnil); } \
static memop_ops memop_ops_##name = { memop_get_##name, memop_put_##name };

NUM_MEMOP(int8, int);
NUM_MEMOP(int16, short);

static VALUE memop_read(VALUE self) {
    struct memop_field f;
    f.ptr = (void *)self;
    f.op = &memop_ops_int8;
    return (*f.op->get)(f.ptr, 0);
}

static VALUE memop_write(VALUE self, VALUE v) {
    struct memop_field f;
    f.ptr = (void *)self;
    f.op = &memop_ops_int16;
    f.op->put(f.ptr, 0, v);
    return self;
}

void Init_api_memop_table(void) {
    VALUE m = rb_define_module("MemopTable");
    rb_define_module_function(m, "read", memop_read, 0);
    rb_define_module_function(m, "write", memop_write, 1);
}
