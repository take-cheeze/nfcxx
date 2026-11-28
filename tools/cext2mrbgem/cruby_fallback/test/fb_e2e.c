/* prototype end-to-end: an mruby script calls CRuby's CF module through the fallback glue, in one process */
#include <stdio.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include "../nfcx_cruby_vm.h"

mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv);

/* Fb.call_cruby(meth, x): CF.<meth>(x) through the fallback (one argument, for the prototype) */
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
    "e = begin; Fb.call_cruby('nope', 1); rescue RuntimeError => ex; ex.message; end\n"
    "[r1, r2, r3, e]";
  mrb_value res = mrb_load_string(mrb, script);
  if (mrb->exc) { printf("FAIL uncaught: %s\n", RSTRING_PTR(mrb_obj_as_string(mrb, mrb_obj_value(mrb->exc)))); return 1; }
  mrb_value a = mrb_ary_ref(mrb, res, 0), b = mrb_ary_ref(mrb, res, 1), c = mrb_ary_ref(mrb, res, 2), d = mrb_ary_ref(mrb, res, 3);
  int ok = mrb_fixnum(a) == 42 && strcmp(RSTRING_PTR(b), "hi") == 0 && mrb_nil_p(c) && strstr(RSTRING_PTR(d), "NoMethodError") != NULL;
  printf("r1=%ld r2=%s r3=%s e=%s\n", (long)mrb_fixnum(a), RSTRING_PTR(b), mrb_nil_p(c) ? "nil" : "?", RSTRING_PTR(d));
  printf(ok ? "e2e OK\n" : "e2e FAILED\n");
  mrb_close(mrb);
  return ok ? 0 : 1;
}
