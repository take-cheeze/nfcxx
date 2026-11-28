/* prototype end-to-end: an mruby script calls CRuby's CF module through the fallback glue (Marshal at the boundary) and
 * drives a stateful CRuby object through a handle, in one process. The mruby build has mruby-marshal (mruby_config.rb). */
#include <stdio.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/variable.h>
#include "../nfcx_cruby_vm.h"

mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv);
mrb_int nfcx_cruby_new_handle(mrb_state *mrb, const char *class_path, const char *ctor, mrb_int argc, const mrb_value *argv);
mrb_value nfcx_cruby_fallback_handle(mrb_state *mrb, mrb_int id, const char *meth, mrb_int argc, const mrb_value *argv);
void nfcx_cruby_release_handle(mrb_state *mrb, mrb_int id);

/* Fb.call_cruby(meth, x): CF.<meth>(x) through the fallback (one argument) */
static mrb_value fb_call(mrb_state *mrb, mrb_value self) {
  mrb_value meth, x;
  (void)self;
  mrb_get_args(mrb, "oo", &meth, &x);
  mrb_value args[1] = {x};
  return nfcx_cruby_fallback(mrb, "CF", RSTRING_PTR(mrb_obj_as_string(mrb, meth)), 1, args);
}

/* Fb::Counter: an instance method's shape. initialize makes the CRuby object and keeps its handle in @__h; add and release
 * dispatch on that handle. */
static mrb_value counter_init(mrb_state *mrb, mrb_value self) {
  mrb_value n;
  mrb_get_args(mrb, "o", &n);
  mrb_int id = nfcx_cruby_new_handle(mrb, "CF::Counter", "new", 1, &n);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@__h"), mrb_fixnum_value(id));
  return self;
}

static mrb_int counter_id(mrb_state *mrb, mrb_value self) {
  (void)mrb;
  return mrb_fixnum(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@__h")));
}

static mrb_value counter_add(mrb_state *mrb, mrb_value self) {
  mrb_value x;
  mrb_get_args(mrb, "o", &x);
  return nfcx_cruby_fallback_handle(mrb, counter_id(mrb, self), "add", 1, &x);
}

static mrb_value counter_release(mrb_state *mrb, mrb_value self) {
  nfcx_cruby_release_handle(mrb, counter_id(mrb, self));
  return mrb_nil_value();
}

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: fb_e2e SO_PATH\n"); return 2; }
  char err[512] = "";
  if (nfcx_cruby_boot(argv[1], err, sizeof err)) { printf("boot failed: %s\n", err); return 1; }
  mrb_state *mrb = mrb_open();
  struct RClass *fb = mrb_define_module(mrb, "Fb");
  mrb_define_module_function(mrb, fb, "call_cruby", fb_call, MRB_ARGS_REQ(2));
  struct RClass *counter = mrb_define_class_under(mrb, fb, "Counter", mrb->object_class);
  mrb_define_method(mrb, counter, "initialize", counter_init, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, counter, "add", counter_add, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, counter, "release", counter_release, MRB_ARGS_NONE());
  const char *script =
    "r1 = Fb.call_cruby('twice', 21)\n"
    "r2 = Fb.call_cruby('echo', 'hi')\n"
    "r3 = Fb.call_cruby('echo', nil)\n"
    "r4 = Fb.call_cruby('echo', [1, 'a', {k: 2.5}, :s])\n"
    "c = Fb::Counter.new(5)\n"
    "a = c.add(3)\n"
    "b = c.add(10)\n"
    "c.release\n"
    "e = begin; c.add(1); rescue RuntimeError => ex; ex.message; end\n"
    "f = begin; Fb.call_cruby('nope', 1); rescue RuntimeError => ex; ex.message; end\n"
    "[r1, r2, r3, r4, a, b, e, f]";
  mrb_value res = mrb_load_string(mrb, script);
  if (mrb->exc) {
    printf("FAIL uncaught: %s\n", RSTRING_PTR(mrb_obj_as_string(mrb, mrb_obj_value(mrb->exc))));
    return 1;
  }
  mrb_value r1 = mrb_ary_ref(mrb, res, 0), r2 = mrb_ary_ref(mrb, res, 1), r3 = mrb_ary_ref(mrb, res, 2);
  mrb_value r4 = mrb_ary_ref(mrb, res, 3), a = mrb_ary_ref(mrb, res, 4), b = mrb_ary_ref(mrb, res, 5);
  mrb_value e = mrb_ary_ref(mrb, res, 6), f = mrb_ary_ref(mrb, res, 7);
  mrb_value r4s = mrb_obj_as_string(mrb, r4);
  mrb_value r4want = mrb_str_new_cstr(mrb, "[1, \"a\", {:k=>2.5}, :s]");
  int ok = mrb_fixnum(r1) == 42 && strcmp(RSTRING_PTR(r2), "hi") == 0 && mrb_nil_p(r3) &&
           RSTRING_LEN(r4s) == RSTRING_LEN(r4want) && memcmp(RSTRING_PTR(r4s), RSTRING_PTR(r4want), RSTRING_LEN(r4s)) == 0 &&
           mrb_fixnum(a) == 8 && mrb_fixnum(b) == 18 && strstr(RSTRING_PTR(e), "released") != NULL &&
           strstr(RSTRING_PTR(f), "NoMethodError") != NULL;
  printf("r1=%ld r2=%s r4=%s a=%ld b=%ld e=%s\n", (long)mrb_fixnum(r1), RSTRING_PTR(r2), RSTRING_PTR(r4s),
         (long)mrb_fixnum(a), (long)mrb_fixnum(b), RSTRING_PTR(e));
  printf(ok ? "e2e OK\n" : "e2e FAILED\n");
  mrb_close(mrb);
  return ok ? 0 : 1;
}
