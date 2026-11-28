/* prototype runner: runs an mruby script with Fb.call(recv, meth, *args) available. Fb.call sends the arguments to the original
 * CRuby extension (Marshal at the boundary) and returns its result; a CRuby error raises RuntimeError.
 * usage: fb_run EXT_SO SCRIPT.rb */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include "../nfcx_cruby_vm.h"

mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv);
mrb_int nfcx_cruby_new_handle(mrb_state *mrb, const char *class_path, const char *ctor, mrb_int argc, const mrb_value *argv);
mrb_value nfcx_cruby_fallback_handle(mrb_state *mrb, mrb_int id, const char *meth, mrb_int argc, const mrb_value *argv);

/* a Symbol or String name copied into buf (NUL-terminated, truncated to fit) */
static void name_copy(mrb_state *mrb, mrb_value v, char *buf, size_t cap) {
  mrb_value s = mrb_obj_as_string(mrb, v);
  snprintf(buf, cap, "%s", RSTRING_PTR(s));
}

/* Fb.call(recv, meth, *args): recv is a constant path such as "MessagePack" */
static mrb_value fb_call(mrb_state *mrb, mrb_value self) {
  mrb_value *argv;
  mrb_int argc;
  (void)self;
  mrb_get_args(mrb, "*", &argv, &argc);
  if (argc < 2) mrb_raise(mrb, E_ARGUMENT_ERROR, "Fb.call needs a receiver and a method");
  char recv[256], meth[256];
  name_copy(mrb, argv[0], recv, sizeof recv);
  name_copy(mrb, argv[1], meth, sizeof meth);
  return nfcx_cruby_fallback(mrb, recv, meth, argc - 2, argv + 2);
}

/* Fb.new(class_path, *args): a CRuby instance (class_path.new(*args)); returns its handle (an Integer) */
static mrb_value fb_new(mrb_state *mrb, mrb_value self) {
  mrb_value *argv;
  mrb_int argc;
  (void)self;
  mrb_get_args(mrb, "*", &argv, &argc);
  if (argc < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "Fb.new needs a class path");
  char cls[256];
  name_copy(mrb, argv[0], cls, sizeof cls);
  return mrb_fixnum_value(nfcx_cruby_new_handle(mrb, cls, "new", argc - 1, argv + 1));
}

/* Fb.send_h(handle, meth, *args): meth on the CRuby object behind a handle */
static mrb_value fb_send_h(mrb_state *mrb, mrb_value self) {
  mrb_value *argv;
  mrb_int argc;
  (void)self;
  mrb_get_args(mrb, "*", &argv, &argc);
  if (argc < 2) mrb_raise(mrb, E_ARGUMENT_ERROR, "Fb.send_h needs a handle and a method");
  char meth[256];
  name_copy(mrb, argv[1], meth, sizeof meth);
  return nfcx_cruby_fallback_handle(mrb, mrb_fixnum(argv[0]), meth, argc - 2, argv + 2);
}

static char *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc((size_t)n + 1);
  if (buf) { fread(buf, 1, (size_t)n, f); buf[n] = 0; *len = (size_t)n; }
  fclose(f);
  return buf;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: fb_run EXT_SO SCRIPT.rb\n"); return 2; }
  char err[512] = "";
  if (nfcx_cruby_boot(argv[1], err, sizeof err)) { printf("boot failed: %s\n", err); return 1; }
  size_t len = 0;
  char *src = read_file(argv[2], &len);
  if (!src) { printf("cannot read %s\n", argv[2]); return 1; }
  mrb_state *mrb = mrb_open();
  struct RClass *fb = mrb_define_module(mrb, "Fb");
  mrb_define_module_function(mrb, fb, "call", fb_call, MRB_ARGS_REQ(2) | MRB_ARGS_REST());
  mrb_define_module_function(mrb, fb, "new", fb_new, MRB_ARGS_REQ(1) | MRB_ARGS_REST());
  mrb_define_module_function(mrb, fb, "send_h", fb_send_h, MRB_ARGS_REQ(2) | MRB_ARGS_REST());
  mrb_load_string(mrb, src);
  int rc = 0;
  if (mrb->exc) {
    mrb_value m = mrb_obj_as_string(mrb, mrb_obj_value(mrb->exc));
    printf("uncaught: %s\n", RSTRING_PTR(m));
    rc = 1;
  }
  mrb_close(mrb);
  free(src);
  return rc;
}
