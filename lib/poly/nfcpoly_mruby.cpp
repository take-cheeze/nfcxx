// nfcpoly Ruby backend: mruby built with C++ exceptions (scripts/setup-poly.sh). See docs/notes/poly.md.
//
// A script raise in this libmruby is `throw (mrb_jmpbuf*)` on the same exception runtime as every C++ `throw` of the
// host, so the rules of nfcpoly_lang.hpp have one consequence specific to this backend: the destructors of the C++
// frames a script raise crosses run (a longjmp would skip them and corrupt the runtime's try stack).
#include "nfcpoly_mruby.hpp"

#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/compile.h>
#include <mruby/data.h>
#include <mruby/error.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <cstdlib>
#include <cstring>
#include <map>

#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

struct MrubyLang;

// What a script object of a bound class holds: the C++ object, and the shared ownership record when the scripts own it.
struct Wrapper {
  void* p;
  Owned* own;
};
void wrapper_free(mrb_state*, void* p) {
  Wrapper* w = static_cast<Wrapper*>(p);
  if (w->own) owned_unref(w->own);
  delete w;
}

struct MClass {
  mrb_data_type type;  // first member: a data object's type pointer is also its MClass
  ClassInfo* ci = nullptr;
  RClass* klass = nullptr;
};

struct MHandle : Handle {
  mrb_state* mrb;
  mrb_value v;
  MHandle(Lang* l, Impl* i, mrb_state* m, mrb_value val) : Handle(l, i), mrb(m), v(val) {
    if (!mrb_immediate_p(v)) mrb_gc_register(mrb, v);
  }
  ~MHandle() override {
    if (lang && mrb && !mrb_immediate_p(v)) mrb_gc_unregister(mrb, v);
  }
  void orphan() override { mrb = nullptr; }
};

// A C++ exception carried by a script exception object (ivar @__host), so that it can come back out unchanged.
struct HostExc {
  std::exception_ptr ep;
};
void host_exc_free(mrb_state*, void* p) { delete static_cast<HostExc*>(p); }
const mrb_data_type host_exc_type = {"NfcPoly::HostException", host_exc_free};

struct ArenaGuard {  // a host loop must not grow the GC arena without bound
  mrb_state* mrb;
  int ai;
  explicit ArenaGuard(mrb_state* m) : mrb(m), ai(mrb_gc_arena_save(m)) {}
  ~ArenaGuard() { mrb_gc_arena_restore(mrb, ai); }
};

[[noreturn]] void raise_class(mrb_state* mrb, const char* cls, const std::string& msg) {
  mrb_exc_raise(mrb, mrb_exc_new_str(mrb, mrb_exc_get(mrb, cls), mrb_str_new(mrb, msg.data(), static_cast<mrb_int>(msg.size()))));
  std::abort();  // not reached: the front end does not see mrb_exc_raise (mrb_noreturn) as noreturn
}

struct CallJob {
  mrb_value self;
  const char* name;
};
mrb_value call_job_body(mrb_state* mrb, void* p) {
  CallJob* j = static_cast<CallJob*>(p);
  return mrb_funcall(mrb, j->self, j->name, 0);
}

struct MethodJob {
  mrb_value self;
  mrb_sym name;
  const mrb_value* argv;
  mrb_int argc;
};
mrb_value method_job_body(mrb_state* mrb, void* p) {
  MethodJob* j = static_cast<MethodJob*>(p);
  return mrb_funcall_argv(mrb, j->self, j->name, j->argc, j->argv);
}

struct EvalJob {
  MrubyLang* lang;
  std::string_view code;
};

mrb_value trampoline(mrb_state* mrb, mrb_value self);
mrb_value value_trampoline(mrb_state* mrb, mrb_value self);
mrb_value no_constructor(mrb_state* mrb, mrb_value self);
mrb_value eval_body(mrb_state* mrb, void* p);

struct MrubyLang : Lang {
  mrb_state* mrb = nullptr;
  mrb_ccontext* cxt = nullptr;
  mrb_value roots = mrb_nil_value();  // an Array held against the GC; slot 0 is the last script exception handed out
  RClass* host_error = nullptr;       // NfcPoly::HostError < RuntimeError: a C++ exception that entered a script
  std::map<ClassInfo*, std::unique_ptr<MClass>> classes;

  explicit MrubyLang(Impl* i) : Lang(i) {
    mrb = mrb_open();
    if (!mrb) throw Error("nfcpoly: mrb_open failed (out of memory)");
    mrb->ud = this;
    cxt = mrb_ccontext_new(mrb);
    cxt->capture_errors = TRUE;
    mrb_ccontext_filename(mrb, cxt, "snippet");
    roots = mrb_ary_new(mrb);
    mrb_gc_register(mrb, roots);
    mrb_ary_set(mrb, roots, 0, mrb_nil_value());
    RClass* mod = mrb_define_module(mrb, "NfcPoly");
    host_error = mrb_define_class_under(mrb, mod, "HostError", mrb_exc_get(mrb, "RuntimeError"));
  }
  ~MrubyLang() override {
    if (mrb) {
      if (cxt) mrb_ccontext_free(mrb, cxt);
      mrb_close(mrb);  // runs the finalizers of script-owned C++ objects
    }
  }
  const char* name() const override { return "ruby"; }

  // ---- values ----
  Var decode(mrb_value v) {  // shallow
    Var r;
    if (mrb_nil_p(v)) {
    } else if (mrb_true_p(v)) {
      r = Var::boolean(true);
    } else if (mrb_false_p(v)) {
      r = Var::boolean(false);
    } else if (mrb_integer_p(v)) {
      r = Var::integer(static_cast<long long>(mrb_integer(v)));
    } else if (mrb_float_p(v)) {
      r = Var::real(static_cast<double>(mrb_float(v)));
    } else if (mrb_string_p(v)) {
      r = Var::string(std::string(RSTRING_PTR(v), static_cast<std::size_t>(RSTRING_LEN(v))));
    } else if (mrb_data_p(v) && DATA_TYPE(v) && DATA_TYPE(v)->dfree == wrapper_free && DATA_PTR(v)) {
      MClass* mc = reinterpret_cast<MClass*>(const_cast<mrb_data_type*>(DATA_TYPE(v)));
      Wrapper* w = static_cast<Wrapper*>(DATA_PTR(v));
      r = Var::object(mc->ci, w->p, w->own);
    } else {
      r = Var::script(new MHandle(this, impl, mrb, v));
    }
    r.set_src(this);
    return r;
  }

  mrb_value encode(const Var& v) {
    switch (v.kind()) {
      case Var::Nil: return mrb_nil_value();
      case Var::Bool: return mrb_bool_value(v.b());
      case Var::Int:
        if (v.i() < static_cast<long long>(MRB_INT_MIN) || v.i() > static_cast<long long>(MRB_INT_MAX))
          range_error("integer does not fit the script's Integer");
        return mrb_int_value(mrb, static_cast<mrb_int>(v.i()));
      case Var::Float: return mrb_float_value(mrb, static_cast<mrb_float>(v.d()));
      case Var::Str: return mrb_str_new(mrb, v.s().data(), static_cast<mrb_int>(v.s().size()));
      case Var::Arr: {
        mrb_value ary = mrb_ary_new_capa(mrb, static_cast<mrb_int>(v.a().size()));
        int ai = mrb_gc_arena_save(mrb);  // ary itself stays protected below this mark
        for (const Var& e : v.a()) {
          mrb_ary_push(mrb, ary, encode(e));
          mrb_gc_arena_restore(mrb, ai);
        }
        return ary;
      }
      case Var::Obj: {
        auto it = classes.find(v.ci());
        if (it == classes.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in ruby");
        Wrapper* w = new Wrapper{v.ptr(), v.owned()};
        if (w->own) owned_ref(w->own);
        return mrb_obj_value(mrb_data_object_alloc(mrb, it->second->klass, w, &it->second->type));
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) return static_cast<MHandle*>(h)->v;
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to ruby");
        return encode(d);
      }
    }
    return mrb_nil_value();
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    ArenaGuard guard(mrb);
    EvalJob job = {this, code};
    mrb_bool err = FALSE;
    mrb_value r = mrb_protect_error(mrb, eval_body, &job, &err);
    if (err) throw_for_exception(r);
    return decode(r);
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    mrb_value rv = static_cast<MHandle*>(v.handle())->v;
    if (!mrb_array_p(rv)) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    ArenaGuard guard(mrb);
    std::vector<Var> out;
    mrb_int n = RARRAY_LEN(rv);
    out.reserve(static_cast<std::size_t>(n));
    for (mrb_int k = 0; k < n; ++k) out.push_back(deep_var(decode(mrb_ary_entry(rv, k)), depth + 1));
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    ArenaGuard guard(mrb);
    std::vector<mrb_value> argv;
    argv.reserve(args.size());
    for (const Var& a : args) argv.push_back(encode(a));
    // An empty name calls the value itself: a Proc answers `call`.
    MethodJob job = {encode(target), mrb_intern_cstr(mrb, method.empty() ? "call" : method.c_str()), argv.data(),
                     static_cast<mrb_int>(argv.size())};
    mrb_bool err = FALSE;
    mrb_value r = mrb_protect_error(mrb, method_job_body, &job, &err);
    if (err) throw_for_exception(r);
    return decode(r);
  }

  std::string inspect(const Var& v) override {
    ArenaGuard guard(mrb);
    return protected_string(encode(v), "inspect");
  }
  std::string type_name(const Var& v) override {
    ArenaGuard guard(mrb);
    return mrb_obj_classname(mrb, encode(v));
  }
  bool is_array(const Var& v) override {
    return v.kind() == Var::Script && v.handle()->lang == this && mrb_array_p(static_cast<MHandle*>(v.handle())->v);
  }

  // ---- declarations ----
  void define_on(RClass* klass, const std::string& name, Callable* c, bool ctor) {
    mrb_value env[2] = {mrb_cptr_value(mrb, c), mrb_bool_value(ctor)};
    RProc* p = mrb_proc_new_cfunc_with_env(mrb, trampoline, 2, env);
    mrb_method_t m;
    MRB_METHOD_FROM_PROC(m, p);
    mrb_define_method_raw(mrb, klass, mrb_intern_cstr(mrb, name.c_str()), m);
  }
  void define_fn(const std::string& name, Callable* c) override { define_on(mrb->kernel_module, name, c, false); }
  void define_value(const std::string& name, const Var& v) override {
    mrb_value val = encode(v);  // held by the method's proc, which the method table keeps alive
    RProc* p = mrb_proc_new_cfunc_with_env(mrb, value_trampoline, 1, &val);
    mrb_method_t m;
    MRB_METHOD_FROM_PROC(m, p);
    mrb_define_method_raw(mrb, mrb->kernel_module, mrb_intern_cstr(mrb, name.c_str()), m);
  }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    define_on(mrb->kernel_module, name, get, false);
    if (set) define_on(mrb->kernel_module, name + "=", set, false);
  }
  void class_define(ClassInfo* ci) override {
    std::unique_ptr<MClass> mc(new MClass);
    mc->ci = ci;
    mc->type.struct_name = ci->name.c_str();
    mc->type.dfree = wrapper_free;
    mc->klass = mrb_define_class(mrb, ci->name.c_str(), mrb->object_class);
    MRB_SET_INSTANCE_TT(mc->klass, MRB_TT_CDATA);
    mrb_define_method(mrb, mc->klass, "initialize", no_constructor, MRB_ARGS_ANY());
    classes[ci] = std::move(mc);
  }
  void class_method(ClassInfo* ci, const std::string& name, Callable* c) override {
    define_on(classes[ci]->klass, name, c, false);
    // The Python-named operator methods are the operators of Ruby too ("Operators" in poly.md). Only `obj OP x`: mruby's Integer
    // and Float do not ask the other operand (no coerce), so `2 - obj` is a TypeError.
    static const char* const ops[][2] = {
        {"__add__", "+"},    {"__sub__", "-"},   {"__mul__", "*"},   {"__truediv__", "/"}, {"__mod__", "%"},
        {"__and__", "&"},    {"__or__", "|"},    {"__xor__", "^"},   {"__neg__", "-@"},    {"__lt__", "<"},
        {"__le__", "<="},    {"__gt__", ">"},    {"__ge__", ">="},   {"__eq__", "=="},     {"__ne__", "!="},
        {"__getitem__", "[]"}, {"__str__", "to_s"}, {"__repr__", "inspect"}};
    for (auto& op : ops)
      if (name == op[0]) define_on(classes[ci]->klass, op[1], c, false);
  }
  void class_prop(ClassInfo* ci, const std::string& name, Callable* get, Callable* set) override {
    define_on(classes[ci]->klass, name, get, false);
    if (set) define_on(classes[ci]->klass, name + "=", set, false);
  }
  void class_ctor(ClassInfo* ci, Callable* c) override { define_on(classes[ci]->klass, "initialize", c, true); }

  // ---- errors ----
  mrb_value protected_call0(mrb_value self, const char* name, bool* ok) {
    CallJob job = {self, name};
    mrb_bool err = FALSE;
    mrb_value r = mrb_protect_error(mrb, call_job_body, &job, &err);
    *ok = !err;
    return r;
  }
  std::string protected_string(mrb_value self, const char* name) {
    bool ok = false;
    mrb_value r = protected_call0(self, name, &ok);
    if (ok && mrb_string_p(r)) return std::string(RSTRING_PTR(r), static_cast<std::size_t>(RSTRING_LEN(r)));
    return std::string();
  }

  // The host side of an exception the interpreter handed back: the original C++ exception when the script carried one
  // out unrescued, else ScriptError (SyntaxError for a parse failure). Never returns.
  [[noreturn]] void throw_for_exception(mrb_value exc) {
    mrb_value h = mrb_iv_get(mrb, exc, mrb_intern_cstr(mrb, "@__host"));
    if (mrb_data_p(h) && DATA_TYPE(h) == &host_exc_type && DATA_PTR(h)) {
      std::exception_ptr ep = static_cast<HostExc*>(DATA_PTR(h))->ep;
      std::rethrow_exception(ep);
    }
    std::string cls = mrb_obj_classname(mrb, exc);
    std::string msg = protected_string(exc, "message");
    std::vector<std::string> bt;
    bool ok = false;
    mrb_value b = protected_call0(exc, "backtrace", &ok);
    if (ok && mrb_array_p(b)) {
      for (mrb_int k = 0; k < RARRAY_LEN(b); ++k) {
        mrb_value line = mrb_ary_entry(b, k);
        if (mrb_string_p(line)) bt.push_back(std::string(RSTRING_PTR(line), static_cast<std::size_t>(RSTRING_LEN(line))));
      }
    }
    mrb_ary_set(mrb, roots, 0, exc);
    raise_script_error(this, cls, msg, std::move(bt), mrb_obj_is_kind_of(mrb, exc, mrb_exc_get(mrb, "SyntaxError")));
  }
};

mrb_value eval_body(mrb_state* mrb, void* p) {
  EvalJob* j = static_cast<EvalJob*>(p);
  j->lang->cxt->lineno = 1;
  mrb_value v = mrb_load_nstring_cxt(mrb, j->code.empty() ? "" : j->code.data(), j->code.size(), j->lang->cxt);
  if (mrb->exc) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));  // report through mrb_protect_error
  return v;
}

// What the trampoline raises once the C++ handlers have finished: building script objects inside them could itself raise.
struct Pending {
  enum Kind { None, Existing, Plain, Host } kind = None;
  std::string cls, msg;
  std::exception_ptr host;
};

[[noreturn]] void raise_pending(MrubyLang* L, Pending& p) {
  mrb_state* mrb = L->mrb;
  if (p.kind == Pending::Existing) mrb_exc_raise(mrb, mrb_ary_entry(L->roots, 0));
  if (p.kind == Pending::Host) {
    mrb_value exc = mrb_exc_new_str(mrb, L->host_error, mrb_str_new(mrb, p.msg.data(), static_cast<mrb_int>(p.msg.size())));
    HostExc* he = new HostExc;
    he->ep = p.host;
    mrb_value d = mrb_obj_value(mrb_data_object_alloc(mrb, mrb->object_class, he, &host_exc_type));
    mrb_obj_iv_set(mrb, mrb_obj_ptr(exc), mrb_intern_cstr(mrb, "@__host"), d);
    mrb_exc_raise(mrb, exc);
  }
  raise_class(mrb, p.cls.c_str(), p.msg);
}

mrb_value trampoline(mrb_state* mrb, mrb_value self) {
  MrubyLang* L = static_cast<MrubyLang*>(mrb->ud);
  Callable* c = static_cast<Callable*>(mrb_cptr(mrb_proc_cfunc_env_get(mrb, 0)));
  bool ctor = mrb_test(mrb_proc_cfunc_env_get(mrb, 1));
  mrb_int argc = mrb_get_argc(mrb);
  if (!arity_fits(c, argc)) raise_class(mrb, "ArgumentError", arity_message(c, argc));
  Pending pend;
  mrb_value result = mrb_nil_value();
  try {
    std::vector<Var> args;
    args.reserve(static_cast<std::size_t>(argc));
    const mrb_value* argv = mrb_get_argv(mrb);
    for (mrb_int k = 0; k < argc; ++k) args.push_back(L->decode(argv[k]));
    arity_pad(c, args);
    if (ctor) {
      if (!mrb_data_p(self)) throw ConversionError("nfcpoly: initialize on a non-bound object");
      if (DATA_PTR(self)) throw ConversionError("nfcpoly: the object is already initialised");
      Var r = c->invoke(nullptr, args.data());  // a new object the script owns
      auto it = L->classes.find(r.ci());
      Wrapper* w = new Wrapper{r.ptr(), r.owned()};
      if (w->own) owned_ref(w->own);
      mrb_data_init(self, w, &it->second->type);
      result = self;
    } else {
      Var selfv;
      const Var* sp = nullptr;
      if (c->wants_self()) {
        selfv = L->decode(self);
        sp = &selfv;
      }
      Var r = c->invoke(sp, args.data());
      result = L->encode(r);
    }
  } catch (void*) {
    throw;  // a script raise passing through on its way to a script handler (mruby throws an mrb_jmpbuf*)
  } catch (const ScriptError& e) {
    if (e.owner() == L && e.serial() == L->exc_serial) {
      pend.kind = Pending::Existing;  // the script exception this came from: raise that very object again
    } else {
      pend.kind = Pending::Plain;
      pend.cls = "RuntimeError";
      pend.msg = e.what();
    }
  } catch (const ConversionError& e) {
    pend.kind = Pending::Plain;
    pend.cls = "TypeError";
    pend.msg = e.what();
  } catch (const std::exception& e) {
    pend.kind = Pending::Host;
    pend.host = std::current_exception();
    pend.msg = e.what();
  } catch (...) {
    pend.kind = Pending::Host;
    pend.host = std::current_exception();
    pend.msg = "unknown C++ exception";
  }
  if (pend.kind != Pending::None) raise_pending(L, pend);
  return result;
}

mrb_value value_trampoline(mrb_state* mrb, mrb_value) { return mrb_proc_cfunc_env_get(mrb, 0); }

mrb_value no_constructor(mrb_state* mrb, mrb_value self) {
  raise_class(mrb, "NoMethodError", std::string(mrb_obj_classname(mrb, self)) + " has no constructor (ClassBuilder::ctor)");
}

std::unique_ptr<Lang> make_ruby(Impl* impl) { return std::unique_ptr<Lang>(new MrubyLang(impl)); }
LangRegistrar registrar("ruby", "mruby", nullptr, &make_ruby);

}  // namespace
}  // namespace detail

mrb_state* mruby_state(Context& ctx) {
  return static_cast<detail::MrubyLang*>(detail::get_lang(ctx.impl(), "ruby"))->mrb;
}

mrb_value mruby_raw(const Value& v) {
  const detail::Var& var = v.var();
  detail::Impl* impl = detail::impl_for(var);  // throws if the Value has no live interpreter
  (void)impl;
  detail::Lang* l = var.kind() == detail::Var::Script ? var.handle()->lang : var.src();
  if (std::strcmp(l->name(), "ruby") != 0) throw Error("nfcpoly: mruby_raw of a value from another language");
  detail::MrubyLang* ml = static_cast<detail::MrubyLang*>(l);
  if (var.kind() == detail::Var::Script) return static_cast<detail::MHandle*>(var.handle())->v;
  return ml->encode(var);
}

}  // namespace nfcpoly
