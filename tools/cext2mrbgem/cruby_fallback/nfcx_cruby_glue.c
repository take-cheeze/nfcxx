/* Prototype (opt-in, --cruby-fallback): the mruby side of the fallback. Arguments go to the embedded CRuby as Marshal.dump
 * bytes, and the result comes back the same way and is loaded with Marshal.load. A CRuby error raises RuntimeError. */
#include <stdio.h>
#include <string.h>
#include <mruby.h>
#include <mruby/string.h>
#include <mruby/error.h>
#include "nfcx_cruby_vm.h"

#define NFCX_CRUBY_MAX_ARGS 16
#define NFCX_CRUBY_RET_CAP 65536
#define NFCX_CRUBY_ERR_CAP 512

/* Marshal.dump(v) as an mruby String */
static mrb_value marshal_dump(mrb_state *mrb, mrb_value v) {
  mrb_value marshal = mrb_obj_value(mrb_module_get(mrb, "Marshal"));
  return mrb_funcall(mrb, marshal, "dump", 1, v);
}

/* Marshal.load(bytes) */
static mrb_value marshal_load(mrb_state *mrb, const char *data, size_t len) {
  mrb_value marshal = mrb_obj_value(mrb_module_get(mrb, "Marshal"));
  mrb_value s = mrb_str_new(mrb, data, (mrb_int)len);
  return mrb_funcall(mrb, marshal, "load", 1, s);
}

/* Calls recv_path.meth(*argv) in the embedded CRuby, with the arguments and the result as Marshal bytes. Returns the result
 * loaded into mruby, or raises RuntimeError with the CRuby exception's class and message. */
mrb_value nfcx_cruby_fallback(mrb_state *mrb, const char *recv_path, const char *meth, mrb_int argc, const mrb_value *argv) {
  if (argc < 0 || argc > NFCX_CRUBY_MAX_ARGS)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "CRuby fallback: too many arguments for the prototype");
  int gc = mrb_gc_arena_save(mrb);
  mrb_value dumped[NFCX_CRUBY_MAX_ARGS];
  const char *data[NFCX_CRUBY_MAX_ARGS];
  size_t len[NFCX_CRUBY_MAX_ARGS];
  for (mrb_int i = 0; i < argc; i++) {
    dumped[i] = marshal_dump(mrb, argv[i]);
    mrb_gc_protect(mrb, dumped[i]);
    data[i] = RSTRING_PTR(dumped[i]);
    len[i] = (size_t)RSTRING_LEN(dumped[i]);
  }
  static char ret_buf[NFCX_CRUBY_RET_CAP];
  size_t ret_len = 0;
  char err[NFCX_CRUBY_ERR_CAP] = "";
  int rc = nfcx_cruby_call(recv_path, meth, (int)argc, data, len, ret_buf, sizeof ret_buf, &ret_len, err, sizeof err);
  mrb_gc_arena_restore(mrb, gc);
  if (rc) mrb_raise(mrb, E_RUNTIME_ERROR, err[0] ? err : "CRuby fallback: call failed");
  return marshal_load(mrb, ret_buf, ret_len);
}

/* Creates a CRuby instance (class_path.ctor(*argv)) and returns its handle index. The object stays in CRuby; mruby keeps the
 * index. Raises RuntimeError on failure. */
mrb_int nfcx_cruby_new_handle(mrb_state *mrb, const char *class_path, const char *ctor, mrb_int argc, const mrb_value *argv) {
  if (argc < 0 || argc > NFCX_CRUBY_MAX_ARGS)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "CRuby fallback: too many arguments for the prototype");
  int gc = mrb_gc_arena_save(mrb);
  mrb_value dumped[NFCX_CRUBY_MAX_ARGS];
  const char *data[NFCX_CRUBY_MAX_ARGS];
  size_t len[NFCX_CRUBY_MAX_ARGS];
  for (mrb_int i = 0; i < argc; i++) {
    dumped[i] = marshal_dump(mrb, argv[i]);
    mrb_gc_protect(mrb, dumped[i]);
    data[i] = RSTRING_PTR(dumped[i]);
    len[i] = (size_t)RSTRING_LEN(dumped[i]);
  }
  long id = -1;
  char err[NFCX_CRUBY_ERR_CAP] = "";
  int rc = nfcx_cruby_handle_new(class_path, ctor, (int)argc, data, len, &id, err, sizeof err);
  mrb_gc_arena_restore(mrb, gc);
  if (rc) mrb_raise(mrb, E_RUNTIME_ERROR, err[0] ? err : "CRuby fallback: constructor failed");
  return (mrb_int)id;
}

/* Calls meth on the CRuby object behind handle id (dispatch by receiver "#<id>") */
mrb_value nfcx_cruby_fallback_handle(mrb_state *mrb, mrb_int id, const char *meth, mrb_int argc, const mrb_value *argv) {
  char path[32];
  snprintf(path, sizeof path, "#%ld", (long)id);
  return nfcx_cruby_fallback(mrb, path, meth, argc, argv);
}

/* Releases handle id; calls on it fail afterwards */
void nfcx_cruby_release_handle(mrb_state *mrb, mrb_int id) {
  char err[NFCX_CRUBY_ERR_CAP] = "";
  if (nfcx_cruby_handle_release((long)id, err, sizeof err))
    mrb_raise(mrb, E_RUNTIME_ERROR, err[0] ? err : "CRuby fallback: release failed");
}
