#include <ruby.h>
static VALUE mWinBranch;
static VALUE wb_run(VALUE self) {
    return INT2FIX(1);
}
#ifdef _WIN32
static VALUE wb_win(VALUE self) {
    return rb_w32_close(0) == 0 ? Qtrue : Qfalse;
}
#endif
void Init_api_win_branch(void) {
    mWinBranch = rb_define_module("WinBranch");
    rb_define_module_function(mWinBranch, "run", wb_run, 0);
}
