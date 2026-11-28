/* prototype end-to-end: an mruby script calls CRuby's CF module through the fallback glue (Marshal at the boundary), in one
 * process. The mruby build has mruby-marshal (mruby_config.rb). */
#include <stdio.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include "../nfcx_cruby_vm.h"

mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv);

/* Fb.call_cruby(meth, x): CF.<meth>(x) through the fallback (one argument) */
static mrb_value fb_call(mrb_state *mrb, mrb_value self) {
  mrb_value meth, x;
  (void)self;
  mrb_get_args(mrb, "oo", &meth, &x);
  mrb_value args[1] = {x};
  return nfcx_cruby_fallback(mrb, "CF", RSTRING_PTR(mrb_obj_as_string(mrb, meth)), 1, args);
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: fb_e2e SO_PATH\n"); return 2; }
  char err[512] = "";
  if (nfcx_cruby_boot(argv[1], err, sizeof err)) { printf("boot failed: %s\n", err); return 1; }
  mrb_state *mrb = mrb_open();
  struct RClass *fb = mrb_define_module(mrb, "Fb");
  mrb_define_module_function(mrb, fb, "call_cruby", fb_call, MRB_ARGS_REQ(2));
  const char *script =
    "r1 = Fb.call_cruby('twice', 21)\n"
    "r2 = Fb.call_cruby('echo', 'hi')\n"
    "r3 = Fb.call_cruby('echo', nil)\n"
    "r4 = Fb.call_cruby('echo', [1, 'a', {k: 2.5}, :s])\n"
    "e = begin; Fb.call_cruby('nope', 1); rescue RuntimeError => ex; ex.message; end\n"
    "[r1, r2, r3, r4, e]";
  mrb_value res = mrb_load_string(mrb, script);
  if (mrb->exc) {
    printf("FAIL uncaught: %s\n", RSTRING_PTR(mrb_obj_as_string(mrb, mrb_obj_value(mrb->exc))));
    return 1;
  }
  mrb_value r1 = mrb_ary_ref(mrb, res, 0), r2 = mrb_ary_ref(mrb, res, 1), r3 = mrb_ary_ref(mrb, res, 2);
  mrb_value r4 = mrb_ary_ref(mrb, res, 3), e = mrb_ary_ref(mrb, res, 4);
  mrb_value r4s = mrb_obj_as_string(mrb, r4);
  mrb_value r4want = mrb_str_new_cstr(mrb, "[1, \"a\", {:k=>2.5}, :s]");
  int ok = mrb_fixnum(r1) == 42 && strcmp(RSTRING_PTR(r2), "hi") == 0 && mrb_nil_p(r3) &&
           RSTRING_LEN(r4s) == RSTRING_LEN(r4want) && memcmp(RSTRING_PTR(r4s), RSTRING_PTR(r4want), RSTRING_LEN(r4s)) == 0 &&
           strstr(RSTRING_PTR(e), "NoMethodError") != NULL;
  printf("r1=%ld r2=%s r3=nil r4=%s e=%s\n", (long)mrb_fixnum(r1), RSTRING_PTR(r2), RSTRING_PTR(r4s), RSTRING_PTR(e));
  printf(ok ? "e2e OK\n" : "e2e FAILED\n");
  mrb_close(mrb);
  return ok ? 0 : 1;
}
