/* Prototype (opt-in, --cruby-fallback): the CRuby side of the fallback. Only this file includes ruby.h, so its names do not
 * meet the mruby ones in the glue file. */
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdio.h>
#include <string.h>
#include "nfcx_cruby_vm.h"

static int booted = 0;

static void put_msg(char *err, size_t errlen, const char *msg) {
  if (err && errlen) snprintf(err, errlen, "%s", msg);
}

/* fills err from the pending exception (class and message) and clears it */
static void put_pending(char *err, size_t errlen, int st) {
  VALUE exc = rb_errinfo();
  rb_set_errinfo(Qnil);
  if (NIL_P(exc)) {
    char b[64];
    snprintf(b, sizeof b, "CRuby error (state %d)", st);
    put_msg(err, errlen, b);
    return;
  }
  VALUE cls = rb_class_name(CLASS_OF(exc));
  VALUE msg = rb_funcall(exc, rb_intern("message"), 0);
  char b[400];
  snprintf(b, sizeof b, "%s: %s", RSTRING_PTR(cls), StringValueCStr(msg));
  put_msg(err, errlen, b);
}

static VALUE require_path(VALUE path) { return rb_require_string(path); }

int nfcx_cruby_boot(const char *so_path, char *err, size_t errlen) {
  if (booted) return 0;
  int argc = 1;
  char *argv_storage[] = {(char *)"nfcx", NULL};
  char **argv = argv_storage;
  ruby_sysinit(&argc, &argv);
  RUBY_INIT_STACK;
  ruby_init();
  int st = 0;
  rb_protect(require_path, rb_str_new_cstr(so_path), &st);
  if (st) {
    put_pending(err, errlen, st);
    return 1;
  }
  booted = 1;
  return 0;
}

typedef struct { VALUE recv; ID meth; int argc; VALUE *argv; } call_args;

static VALUE do_call(VALUE a) {
  call_args *c = (call_args *)a;
  return rb_funcallv(c->recv, c->meth, c->argc, c->argv);
}

static VALUE resolve_path(VALUE path) { return rb_path_to_class(path); }

static VALUE load_one(VALUE data) { return rb_marshal_load(data); }
static VALUE dump_one(VALUE v) { return rb_marshal_dump(v, Qnil); }

int nfcx_cruby_call(const char *recv_path, const char *meth, int argc, const char *const *arg_data, const size_t *arg_len,
                    char *ret_buf, size_t ret_cap, size_t *ret_len, char *err, size_t errlen) {
  if (!booted) { put_msg(err, errlen, "CRuby VM not booted"); return 1; }
  int st = 0;
  VALUE recv = rb_protect(resolve_path, rb_str_new_cstr(recv_path), &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  VALUE *vals = NULL;
  if (argc > 0) {
    vals = ALLOCA_N(VALUE, (size_t)argc);
    for (int i = 0; i < argc; i++) {
      VALUE data = rb_str_new(arg_data[i], (long)arg_len[i]);
      vals[i] = rb_protect(load_one, data, &st);
      if (st) { put_pending(err, errlen, st); return 1; }
    }
  }
  call_args c = {recv, rb_intern(meth), argc, vals};
  VALUE result = rb_protect(do_call, (VALUE)&c, &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  VALUE dumped = rb_protect(dump_one, result, &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  if (RSTRING_LEN(dumped) < 0 || (size_t)RSTRING_LEN(dumped) > ret_cap) {
    put_msg(err, errlen, "result does not fit the return buffer");
    return 1;
  }
  memcpy(ret_buf, RSTRING_PTR(dumped), (size_t)RSTRING_LEN(dumped));
  *ret_len = (size_t)RSTRING_LEN(dumped);
  return 0;
}
