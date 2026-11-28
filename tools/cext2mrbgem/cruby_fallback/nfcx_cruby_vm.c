/* Prototype (opt-in, --cruby-fallback): the CRuby side of the fallback. Only this file includes ruby.h, so its names do not
 * meet the mruby ones in the glue file.
 *
 * Handles: an instance whose state lives in CRuby (a C-backed object) is kept in the handles table, and the mruby side holds
 * only its index. A receiver path "#<index>" names that object, so method dispatch is nfcx_cruby_call("#<index>", meth, ...).
 * A released index is nil in the table; calls on it fail. */
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nfcx_cruby_vm.h"

static int booted = 0;
static VALUE handles; /* Array of the CRuby objects behind handles; registered with the GC at boot */

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
  handles = rb_ary_new();
  rb_gc_register_address(&handles);
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

/* the object behind a "#<index>" receiver; 0 when the index is unknown or released */
static int handle_value(const char *recv_path, VALUE *out) {
  char *end = NULL;
  long id = strtol(recv_path + 1, &end, 10);
  if (end == recv_path + 1 || *end != '\0' || id < 0 || id >= RARRAY_LEN(handles)) return 0;
  VALUE v = rb_ary_entry(handles, id);
  if (NIL_P(v)) return 0;
  *out = v;
  return 1;
}

/* the receiver of a call: a constant path, or a handle */
static int resolve_recv(const char *recv_path, VALUE *out, int *st, char *err, size_t errlen) {
  if (recv_path[0] == '#') {
    if (!handle_value(recv_path, out)) { put_msg(err, errlen, "unknown or released handle"); return 0; }
    return 1;
  }
  *out = rb_protect(resolve_path, rb_str_new_cstr(recv_path), st);
  if (*st) { put_pending(err, errlen, *st); return 0; }
  return 1;
}

/* loads the Marshal bytes of each argument into vals */
static int load_args(int argc, const char *const *arg_data, const size_t *arg_len, VALUE *vals, int *st, char *err, size_t errlen) {
  for (int i = 0; i < argc; i++) {
    VALUE data = rb_str_new(arg_data[i], (long)arg_len[i]);
    vals[i] = rb_protect(load_one, data, st);
    if (*st) { put_pending(err, errlen, *st); return 0; }
  }
  return 1;
}

int nfcx_cruby_call(const char *recv_path, const char *meth, int argc, const char *const *arg_data, const size_t *arg_len,
                    char *ret_buf, size_t ret_cap, size_t *ret_len, char *err, size_t errlen) {
  if (!booted) { put_msg(err, errlen, "CRuby VM not booted"); return 1; }
  int st = 0;
  VALUE recv;
  if (!resolve_recv(recv_path, &recv, &st, err, errlen)) return 1;
  VALUE *vals = NULL;
  if (argc > 0) {
    vals = ALLOCA_N(VALUE, (size_t)argc);
    if (!load_args(argc, arg_data, arg_len, vals, &st, err, errlen)) return 1;
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

int nfcx_cruby_handle_new(const char *recv_path, const char *ctor, int argc, const char *const *arg_data,
                          const size_t *arg_len, long *id, char *err, size_t errlen) {
  if (!booted) { put_msg(err, errlen, "CRuby VM not booted"); return 1; }
  int st = 0;
  VALUE klass;
  if (recv_path[0] == '#' || !resolve_recv(recv_path, &klass, &st, err, errlen)) {
    if (recv_path[0] == '#') put_msg(err, errlen, "a constructor receiver is a constant path, not a handle");
    return 1;
  }
  VALUE *vals = NULL;
  if (argc > 0) {
    vals = ALLOCA_N(VALUE, (size_t)argc);
    if (!load_args(argc, arg_data, arg_len, vals, &st, err, errlen)) return 1;
  }
  call_args c = {klass, rb_intern(ctor), argc, vals};
  VALUE obj = rb_protect(do_call, (VALUE)&c, &st);
  if (st) { put_pending(err, errlen, st); return 1; }
  rb_ary_push(handles, obj);
  *id = (long)RARRAY_LEN(handles) - 1;
  return 0;
}

int nfcx_cruby_handle_release(long id, char *err, size_t errlen) {
  if (!booted) { put_msg(err, errlen, "CRuby VM not booted"); return 1; }
  if (id < 0 || id >= RARRAY_LEN(handles)) { put_msg(err, errlen, "unknown handle"); return 1; }
  rb_ary_store(handles, id, Qnil);
  return 0;
}
