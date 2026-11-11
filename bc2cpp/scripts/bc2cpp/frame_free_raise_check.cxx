// A native called with mrb_call_direct against the same native called through a pushed frame (mrb_funcall_with_method):
// the same result, the same exception (class, message, backtrace length) and the same depth of frames afterwards, and
// no frame pushed for a call that returns normally. With mrb->frame_free_p set, mrb_funcall_with_method makes the same
// call frame-free for any caller, and so does mrb_obj_new's initialize.
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <stdio.h>
#include <string.h>
#include <string>

extern "C" mrb_value mrb_funcall_with_method(mrb_state*, mrb_value, mrb_sym, const mrb_method_t*, struct RClass*, mrb_int, const mrb_value*, mrb_value);

static ptrdiff_t seen_depth;
static ptrdiff_t depth(mrb_state* mrb) { return mrb->c->ci - mrb->c->cibase; }

static mrb_value n_double(mrb_state* mrb, mrb_value self) {
  mrb_int n;
  mrb_get_args(mrb, "i", &n);
  seen_depth = depth(mrb);
  if (n < 0) mrb_raise(mrb, E_ARGUMENT_ERROR, "negative");
  return mrb_int_value(mrb, n * 2);
}
static mrb_value n_check(mrb_state* mrb, mrb_value self) {
  mrb_int n;
  mrb_get_args(mrb, "i", &n);
  if (n == 3) mrb_raise(mrb, E_RUNTIME_ERROR, "three");
  return mrb_int_value(mrb, n);
}
static mrb_value n_nested(mrb_state* mrb, mrb_value self) {
  mrb_int n;
  mrb_get_args(mrb, "i", &n);
  seen_depth = depth(mrb);
  return mrb_funcall(mrb, self, "check", 1, mrb_int_value(mrb, n));
}
static mrb_value n_argc(mrb_state* mrb, mrb_value self) {
  mrb_int argc = mrb_get_argc(mrb);
  const mrb_value* argv = mrb_get_argv(mrb);
  seen_depth = depth(mrb);
  mrb_int sum = 0;
  for (mrb_int i = 0; i < argc; i++) sum += mrb_integer(argv[i]);
  return mrb_int_value(mrb, sum);
}
static mrb_value n_init(mrb_state* mrb, mrb_value self) {
  mrb_int n = 0;
  mrb_get_args(mrb, "|i", &n);
  seen_depth = depth(mrb);
  if (n < 0) mrb_raise(mrb, E_ARGUMENT_ERROR, "negative init");
  return self;
}
static mrb_bool all_free(mrb_state*, mrb_func_t) { return TRUE; }
static mrb_value n_opt(mrb_state* mrb, mrb_value self) {
  mrb_value a, b = mrb_nil_value();
  mrb_bool given;
  mrb_get_args(mrb, "o|o?", &a, &b, &given);
  seen_depth = depth(mrb);
  return mrb_bool_value(given);
}

struct Outcome { bool raised; std::string repr; ptrdiff_t bt; ptrdiff_t depth_after; ptrdiff_t depth_inside; };

static Outcome run(mrb_state* mrb, int mode, mrb_value self, const char* name, mrb_int argc, const mrb_value* argv) {
  struct RClass* c = mrb_class(mrb, self);
  mrb_sym mid = mrb_intern_cstr(mrb, name);
  mrb_method_t m = mrb_method_search_vm(mrb, &c, mid);
  Outcome o{};
  ptrdiff_t before = depth(mrb);
  seen_depth = -1;
  struct Call { mrb_value self; mrb_sym mid; mrb_method_t* m; struct RClass* c; mrb_int argc; const mrb_value* argv; int mode; } call{self, mid, &m, c, argc, argv, mode};
  mrb->frame_free_p = mode == 2 ? all_free : nullptr;
  mrb_bool error = FALSE;
  mrb_value r = mrb_protect_error(mrb, [](mrb_state* mrb, void* p) -> mrb_value {
    Call* k = (Call*)p;
    if (k->mode == 1) return mrb_call_direct(mrb, k->self, k->mid, MRB_METHOD_FUNC(*k->m), k->c, k->argc, k->argv);
    return mrb_funcall_with_method(mrb, k->self, k->mid, k->m, k->c, k->argc, k->argv, mrb_nil_value());
  }, &call, &error);
  o.raised = error;
  o.depth_inside = seen_depth - before;
  if (error) {
    mrb_value cls = mrb_funcall(mrb, mrb_obj_value(mrb_obj_class(mrb, r)), "to_s", 0);
    mrb_value msg = mrb_funcall(mrb, r, "message", 0);
    o.repr = std::string(RSTRING_PTR(cls), RSTRING_LEN(cls)) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    mrb_value bt = mrb_funcall(mrb, r, "backtrace", 0);
    o.bt = mrb_array_p(bt) ? RARRAY_LEN(bt) : -1;
  } else {
    o.repr = mrb_integer_p(r) ? std::to_string(mrb_integer(r)) : (mrb_true_p(r) ? "true" : mrb_false_p(r) ? "false" : "?");
    o.bt = 0;
  }
  o.depth_after = depth(mrb) - before;
  mrb->frame_free_p = nullptr;
  return o;
}

static Outcome construct(mrb_state* mrb, bool hooked, struct RClass* k, mrb_int argc, const mrb_value* argv) {
  Outcome o{};
  ptrdiff_t before = depth(mrb);
  seen_depth = -1;
  mrb->frame_free_p = hooked ? all_free : nullptr;
  struct Call { struct RClass* k; mrb_int argc; const mrb_value* argv; } call{k, argc, argv};
  mrb_bool error = FALSE;
  mrb_value r = mrb_protect_error(mrb, [](mrb_state* mrb, void* p) -> mrb_value {
    Call* c = (Call*)p;
    return mrb_obj_new(mrb, c->k, c->argc, c->argv);
  }, &call, &error);
  o.raised = error;
  o.depth_inside = seen_depth - before;
  if (error) {
    mrb_value msg = mrb_funcall(mrb, r, "message", 0);
    o.repr = std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    mrb_value bt = mrb_funcall(mrb, r, "backtrace", 0);
    o.bt = mrb_array_p(bt) ? RARRAY_LEN(bt) : -1;
  }
  o.depth_after = depth(mrb) - before;
  mrb->frame_free_p = nullptr;
  return o;
}

int main() {
  mrb_state* mrb = mrb_open_core();
  struct RClass* k = mrb_define_class(mrb, "Thing", mrb->object_class);
  mrb_define_method(mrb, k, "double", n_double, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, k, "check", n_check, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, k, "nested", n_nested, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, k, "argc", n_argc, MRB_ARGS_ANY());
  mrb_define_method(mrb, k, "opt", n_opt, MRB_ARGS_ARG(1, 1));
  mrb_value self = mrb_obj_new(mrb, k, 0, nullptr);
  mrb_value one = mrb_int_value(mrb, 4), neg = mrb_int_value(mrb, -1), three = mrb_int_value(mrb, 3);
  mrb_value two[2] = { mrb_int_value(mrb, 5), mrb_int_value(mrb, 7) };
  struct Case { const char* name; mrb_int argc; const mrb_value* argv; bool pushed_when_direct; } cases[] = {
    { "double", 1, &one, false },     /* normal return */
    { "double", 1, &neg, true },      /* raised in the native: its frame is in the backtrace */
    { "double", 0, nullptr, true },   /* mrb_get_args arity error */
    { "nested", 1, &one, true },      /* a send from the native: its frame goes below the callee's */
    { "nested", 1, &three, true },    /* raised in the nested native */
    { "argc", 2, two, false },        /* the argument readers */
    { "opt", 1, &one, false },        /* optional argument format */
    { "opt", 2, two, false },
  };
  int failures = 0, total = 0;
  for (const Case& c : cases) {
    Outcome f = run(mrb, 0, self, c.name, c.argc, c.argv);
    Outcome d = run(mrb, 1, self, c.name, c.argc, c.argv);
    Outcome h = run(mrb, 2, self, c.name, c.argc, c.argv); /* mrb_funcall_with_method with the hook: as direct */
    bool same = f.raised == d.raised && f.repr == d.repr && f.bt == d.bt && f.depth_after == d.depth_after &&
                h.raised == d.raised && h.repr == d.repr && h.bt == d.bt && h.depth_after == d.depth_after &&
                h.depth_inside == d.depth_inside;
    bool frames = c.pushed_when_direct ? true : (d.depth_inside == f.depth_inside - 1);
    ++total;
    printf("%s %s(%d): framed{%s %s bt=%ld} direct{%s %s bt=%ld} inside framed=%ld direct=%ld\n", same && frames ? "ok  " : "FAIL", c.name, (int)c.argc,
           f.raised ? "raised" : "value", f.repr.c_str(), (long)f.bt, d.raised ? "raised" : "value", d.repr.c_str(), (long)d.bt,
           (long)f.depth_inside, (long)d.depth_inside);
    if (!(same && frames)) ++failures;
  }
  /* mrb_obj_new's initialize, a C caller of mrb_funcall_with_method */
  struct RClass* ik = mrb_define_class(mrb, "Built", mrb->object_class);
  mrb_define_method(mrb, ik, "initialize", n_init, MRB_ARGS_OPT(1));
  for (const mrb_value* arg : { &one, &neg }) {
    Outcome f = construct(mrb, false, ik, 1, arg);
    Outcome h = construct(mrb, true, ik, 1, arg);
    bool same = f.raised == h.raised && f.repr == h.repr && f.bt == h.bt && f.depth_after == h.depth_after;
    bool frames = f.raised || h.depth_inside == f.depth_inside - 1;
    ++total;
    printf("%s new(%ld): framed{%s bt=%ld inside=%ld} hooked{%s bt=%ld inside=%ld}\n", same && frames ? "ok  " : "FAIL",
           (long)mrb_integer(*arg), f.raised ? "raised" : "value", (long)f.bt, (long)f.depth_inside, h.raised ? "raised" : "value",
           (long)h.bt, (long)h.depth_inside);
    if (!(same && frames)) ++failures;
  }
  printf("frame_free_raise_check: %d of %d cases %s\n", total - failures, total, failures ? "FAILED" : "pass");
  mrb_close(mrb);
  return failures ? 1 : 0;
}

// The check links the core alone: no gem's init runs (gem_init.o is not pulled in).
extern "C" void mrb_init_mrbgems(mrb_state*) {}
