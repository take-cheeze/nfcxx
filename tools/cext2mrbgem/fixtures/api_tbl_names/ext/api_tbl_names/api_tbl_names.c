#include <ruby.h>
typedef struct { int (*on_null)(void *ctx); } cbs_t;
typedef struct { cbs_t *cbs; } holder_t;
static int tn_null(void *ctx) {
    rb_funcall(Qnil, rb_intern("to_s"), 0);
    return 1;
}
static cbs_t tn_table = { tn_null };
static int tn_use(const cbs_t *cbs, void *ctx);
static VALUE mTblNames;
static int tn_use(const cbs_t *cbs, void *ctx) {
    holder_t h;
    h.cbs = (cbs_t *)cbs;
    return h.cbs->on_null(ctx);
}
static VALUE tn_run(VALUE self) {
    holder_t h;
    h.cbs = &tn_table;
    int ok = tn_use(h.cbs, NULL);
    return ok ? Qtrue : Qfalse;
}
void Init_api_tbl_names(void) {
    mTblNames = rb_define_module("TblNames");
    rb_define_module_function(mTblNames, "run", tn_run, 0);
}
