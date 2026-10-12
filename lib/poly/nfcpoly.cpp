// nfcpoly implementation. See nfcpoly.hpp and docs/notes/poly.md.
//
// libmruby is built with C++ exceptions (scripts/mruby-rt-config.rb): a script raise is `throw (mrb_jmpbuf*)` on the
// same exception runtime as every C++ `throw` in the host. Three rules follow from that and are kept here:
//   1. Every call from C++ into the interpreter goes through mrb_protect_error (or checks mrb->exc), so a script
//      error becomes a C++ exception (ScriptError) and never unwinds host frames that do not expect it.
//   2. Every call from the interpreter into C++ goes through `trampoline`, which catches whatever the bound code
//      throws and raises a script exception instead. A foreign C++ exception passing through the VM would leave
//      mrb->jmp and the call stack inconsistent. The one type it must not catch is mruby's own `mrb_jmpbuf*`: a
//      script raise that is merely passing through a bound function on its way to a script handler.
//   3. mruby's raise runs the destructors of the C++ frames it crosses (that is what C++ exceptions buy over
//      longjmp), so a bound function's RAII objects are released when a script it called back into raises.
#ifndef MRB_USE_CXX_EXCEPTION
#define MRB_USE_CXX_EXCEPTION  // as libmruby was built; only <mruby/throw.h>, for the type mrb_jmpbuf, depends on it
#endif
#include "nfcpoly.hpp"

#include <mruby/class.h>
#include <mruby/compile.h>
#include <mruby/data.h>
#include <mruby/error.h>
#include <mruby/proc.h>
#include <mruby/throw.h>
#include <mruby/variable.h>

#include <cctype>
#include <cstdlib>

namespace nfcpoly {
namespace detail {

namespace {
unsigned long g_serial = 0;  // script exception objects handed to the host, numbered across all contexts
}

struct ClassInfo {
  std::string name;
  RClass* klass = nullptr;
  mrb_data_type ref_type = {nullptr, nullptr};  // wrapper of an object the host owns
  mrb_data_type own_type = {nullptr, nullptr};  // wrapper of an object the script's GC owns
};

struct Impl {
  mrb_state* mrb = nullptr;
  mrb_ccontext* cxt = nullptr;
  std::map<const void*, std::unique_ptr<ClassInfo>> classes;
  std::vector<std::unique_ptr<Callable>> callables;
  mrb_value roots = mrb_nil_value();  // an Array held against the GC; slot 0 is the last script exception handed out
  unsigned long exc_serial = 0;
  RClass* host_error = nullptr;       // NfcPoly::HostError < RuntimeError: a C++ exception that entered a script
  ~Impl() {
    if (mrb) {
      if (cxt) mrb_ccontext_free(mrb, cxt);
      mrb_close(mrb);  // runs the finalizers of script-owned C++ objects, so classes (their data types) outlive it
    }
  }
};

namespace {

Impl* impl_of(mrb_state* mrb) { return static_cast<Impl*>(mrb->ud); }

// A C++ exception carried by a script exception object (ivar @__host), so that it can come back out unchanged.
struct HostExc {
  std::exception_ptr ep;
};
void host_exc_free(mrb_state*, void* p) { delete static_cast<HostExc*>(p); }
const mrb_data_type host_exc_type = {"NfcPoly::HostException", host_exc_free};

[[noreturn]] void raise_class(mrb_state* mrb, const char* cls, const std::string& msg) {
  mrb_exc_raise(mrb, mrb_exc_new_str(mrb, mrb_exc_get(mrb, cls), mrb_str_new(mrb, msg.data(), static_cast<mrb_int>(msg.size()))));
  std::abort();  // not reached: the front end does not see mrb_exc_raise (mrb_noreturn) as noreturn
}

// Text of a script method (message, inspect), or "" when it raises or does not answer a String.
struct CallJob {
  mrb_value self;
  const char* name;
};
mrb_value call_job_body(mrb_state* mrb, void* p) {
  CallJob* j = static_cast<CallJob*>(p);
  return mrb_funcall(mrb, j->self, j->name, 0);
}
mrb_value protected_call0(Impl* i, mrb_value self, const char* name, bool* ok) {
  CallJob job = {self, name};
  mrb_bool err = FALSE;
  mrb_value r = mrb_protect_error(i->mrb, call_job_body, &job, &err);
  *ok = !err;
  return r;
}
std::string protected_string(Impl* i, mrb_value self, const char* name) {
  bool ok = false;
  mrb_value r = protected_call0(i, self, name, &ok);
  if (ok && mrb_string_p(r)) return std::string(RSTRING_PTR(r), static_cast<std::size_t>(RSTRING_LEN(r)));
  return std::string();
}

// The host side of an exception the interpreter handed back: the original C++ exception when the script carried one
// out unrescued, else ScriptError (SyntaxError for a parse failure). Never returns.
[[noreturn]] void throw_for_exception(Impl* i, mrb_value exc) {
  mrb_state* mrb = i->mrb;
  mrb_value h = mrb_iv_get(mrb, exc, mrb_intern_cstr(mrb, "@__host"));
  if (mrb_data_p(h) && DATA_TYPE(h) == &host_exc_type && DATA_PTR(h)) {
    std::exception_ptr ep = static_cast<HostExc*>(DATA_PTR(h))->ep;
    std::rethrow_exception(ep);
  }
  std::string cls = mrb_obj_classname(mrb, exc);
  std::string msg = protected_string(i, exc, "message");
  std::vector<std::string> bt;
  {
    bool ok = false;
    mrb_value b = protected_call0(i, exc, "backtrace", &ok);
    if (ok && mrb_array_p(b)) {
      for (mrb_int k = 0; k < RARRAY_LEN(b); ++k) {
        mrb_value line = mrb_ary_entry(b, k);
        if (mrb_string_p(line)) bt.push_back(std::string(RSTRING_PTR(line), static_cast<std::size_t>(RSTRING_LEN(line))));
      }
    }
  }
  mrb_ary_set(mrb, i->roots, 0, exc);
  i->exc_serial = ++g_serial;
  if (mrb_obj_is_kind_of(mrb, exc, mrb_exc_get(mrb, "SyntaxError"))) throw SyntaxError(cls + ": " + msg);
  throw ScriptError(cls, msg, std::move(bt), i, i->exc_serial);
}

// ---- running C++ from a script -----------------------------------------------------------------------------------
// What the trampoline raises, decided inside the C++ handlers and carried out after them: building script objects
// there could itself raise (out of memory) while a C++ exception is being handled.
struct Pending {
  enum Kind { None, Existing, Plain, Host } kind = None;
  std::string cls, msg;
  std::exception_ptr host;
};

[[noreturn]] void raise_pending(Impl* i, mrb_state* mrb, Pending& p) {
  if (p.kind == Pending::Existing) {
    mrb_exc_raise(mrb, mrb_ary_entry(i->roots, 0));
  }
  if (p.kind == Pending::Host) {
    mrb_value exc = mrb_exc_new_str(mrb, i->host_error, mrb_str_new(mrb, p.msg.data(), static_cast<mrb_int>(p.msg.size())));
    HostExc* he = new HostExc;
    he->ep = p.host;
    mrb_value d = mrb_obj_value(mrb_data_object_alloc(mrb, mrb->object_class, he, &host_exc_type));
    mrb_obj_iv_set(mrb, mrb_obj_ptr(exc), mrb_intern_cstr(mrb, "@__host"), d);
    mrb_exc_raise(mrb, exc);
  }
  raise_class(mrb, p.cls.c_str(), p.msg);
}

mrb_value trampoline(mrb_state* mrb, mrb_value self) {
  Impl* impl = impl_of(mrb);
  Callable* c = static_cast<Callable*>(mrb_cptr(mrb_proc_cfunc_env_get(mrb, 0)));
  mrb_int argc = mrb_get_argc(mrb);
  if (argc != c->arity()) {
    raise_class(mrb, "ArgumentError",
                "wrong number of arguments (given " + std::to_string(argc) + ", expected " + std::to_string(c->arity()) + ")");
  }
  Pending pend;
  mrb_value result = mrb_nil_value();
  try {
    result = c->invoke(mrb, self, argc, mrb_get_argv(mrb));
  } catch (mrb_jmpbuf*) {
    throw;  // a script raise passing through on its way to a script handler
  } catch (const ScriptError& e) {
    if (e.owner() == impl && e.serial() == impl->exc_serial) {
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
  if (pend.kind != Pending::None) raise_pending(impl, mrb, pend);
  return result;
}

class ValueCallable : public Callable {
 public:
  explicit ValueCallable(mrb_value v) : v_(v) {}
  int arity() const override { return 0; }
  mrb_value invoke(mrb_state*, mrb_value, mrb_int, const mrb_value*) override { return v_; }

 private:
  mrb_value v_;
};

void define_on(Impl* i, RClass* klass, const std::string& name, std::unique_ptr<Callable> c) {
  mrb_state* mrb = i->mrb;
  mrb_value env = mrb_cptr_value(mrb, c.get());
  RProc* p = mrb_proc_new_cfunc_with_env(mrb, trampoline, 1, &env);
  mrb_method_t m;
  MRB_METHOD_FROM_PROC(m, p);
  mrb_define_method_raw(mrb, klass, mrb_intern_cstr(mrb, name.c_str()), m);
  i->callables.push_back(std::move(c));
}

bool ident_char(char c, bool first) {
  unsigned char u = static_cast<unsigned char>(c);
  return std::isalpha(u) || c == '_' || (!first && std::isdigit(u));
}

// A name the script can write as a bare identifier: it starts with a lower-case letter or '_' (an upper-case one would
// parse as a constant), and may end in '?', '!' or '=' (a setter).
void check_global_name(const std::string& name) {
  std::size_t n = name.size();
  if (n > 0 && (name[n - 1] == '?' || name[n - 1] == '!' || name[n - 1] == '=')) --n;
  bool ok = n > 0 && ident_char(name[0], true) && !std::isupper(static_cast<unsigned char>(name[0]));
  for (std::size_t k = 1; ok && k < n; ++k) ok = ident_char(name[k], false);
  if (!ok) throw Error("nfcpoly: '" + name + "' is not a usable global name (a lower-case identifier)");
}

mrb_value no_constructor(mrb_state* mrb, mrb_value self) {
  raise_class(mrb, "NoMethodError", std::string(mrb_obj_classname(mrb, self)) + " has no constructor (ClassBuilder::ctor)");
}

}  // namespace

mrb_state* state_of(Impl* impl) { return impl->mrb; }

void root_add(Impl* impl, mrb_value v) {
  if (!mrb_immediate_p(v)) mrb_gc_register(impl->mrb, v);
}
void root_del(Impl* impl, mrb_value v) {
  if (!mrb_immediate_p(v)) mrb_gc_unregister(impl->mrb, v);
}

Value make_value(Impl* impl, mrb_value v) { return Value(impl, v); }

ClassInfo* find_class(mrb_state* mrb, const void* key) {
  Impl* i = impl_of(mrb);
  auto it = i->classes.find(key);
  return it == i->classes.end() ? nullptr : it->second.get();
}

void conversion_error(mrb_state* mrb, mrb_value v, const char* want) {
  throw ConversionError(std::string("expected ") + want + ", got " + mrb_obj_classname(mrb, v));
}
void range_error(const char* what) { throw ConversionError(what); }
void unregistered_class(const char* what) {
  throw ConversionError(std::string("nfcpoly: a C++ ") + what + " crossed into the script without Context::def_class");
}
void empty_value() { throw Error("nfcpoly: the Value is empty (default constructed)"); }

mrb_value cstr_value(mrb_state* mrb, const char* s) { return s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value(); }

Value Conv<Value>::from(mrb_state* mrb, mrb_value v) { return make_value(impl_of(mrb), v); }

void* unwrap_object(mrb_state* mrb, ClassInfo* ci, mrb_value v, bool allow_nil) {
  if (allow_nil && mrb_nil_p(v)) return nullptr;
  if (mrb_data_p(v) && (DATA_TYPE(v) == &ci->ref_type || DATA_TYPE(v) == &ci->own_type)) {
    void* p = DATA_PTR(v);
    if (!p) throw ConversionError("nfcpoly: " + ci->name + " object is not initialised");
    return p;
  }
  conversion_error(mrb, v, ci->name.c_str());
}

mrb_value wrap_borrowed(mrb_state* mrb, ClassInfo* ci, void* p) {
  return mrb_obj_value(mrb_data_object_alloc(mrb, ci->klass, p, &ci->ref_type));
}
mrb_value wrap_owned(mrb_state* mrb, ClassInfo* ci, void* p) {
  return mrb_obj_value(mrb_data_object_alloc(mrb, ci->klass, p, &ci->own_type));
}

ClassInfo* register_class(Impl* i, const void* key, const std::string& name, void (*deleter)(mrb_state*, void*)) {
  if (name.empty() || !std::isupper(static_cast<unsigned char>(name[0])))
    throw Error("nfcpoly: '" + name + "' is not a script class name (a constant: upper-case first letter)");
  for (std::size_t k = 1; k < name.size(); ++k)
    if (!ident_char(name[k], false)) throw Error("nfcpoly: '" + name + "' is not a script class name");
  if (i->classes.count(key)) throw Error("nfcpoly: this C++ class is already registered as " + i->classes[key]->name);
  for (auto& kv : i->classes)
    if (kv.second->name == name) throw Error("nfcpoly: the script class name " + name + " is already registered");
  std::unique_ptr<ClassInfo> ci(new ClassInfo);
  ci->name = name;
  ci->ref_type.struct_name = ci->name.c_str();
  ci->ref_type.dfree = nullptr;
  ci->own_type.struct_name = ci->name.c_str();
  ci->own_type.dfree = deleter;
  ci->klass = mrb_define_class(i->mrb, name.c_str(), i->mrb->object_class);
  MRB_SET_INSTANCE_TT(ci->klass, MRB_TT_CDATA);
  mrb_define_method(i->mrb, ci->klass, "initialize", no_constructor, MRB_ARGS_ANY());
  ClassInfo* raw = ci.get();
  i->classes[key] = std::move(ci);
  return raw;
}

void define_global_fn(Impl* i, const std::string& name, std::unique_ptr<Callable> c) {
  check_global_name(name);
  define_on(i, i->mrb->kernel_module, name, std::move(c));
}

void define_global_value(Impl* i, const std::string& name, mrb_value v) {
  check_global_name(name);
  root_add(i, v);  // the context's lifetime: released with the interpreter
  define_on(i, i->mrb->kernel_module, name, std::unique_ptr<Callable>(new ValueCallable(v)));
}

void define_method(Impl* i, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> c) {
  if (name.empty()) throw Error("nfcpoly: empty method name");
  define_on(i, ci->klass, name, std::move(c));
}

void define_initializer(Impl* i, ClassInfo* ci, std::unique_ptr<Callable> c) {
  define_on(i, ci->klass, "initialize", std::move(c));
}

void check_uninitialised(mrb_state*, ClassInfo* ci, mrb_value self) {
  if (!mrb_data_p(self)) throw ConversionError("nfcpoly: " + ci->name + "#initialize on a non-" + ci->name + " object");
  if (DATA_PTR(self)) throw ConversionError("nfcpoly: " + ci->name + " object is already initialised");
}

void init_owned(mrb_state*, ClassInfo* ci, mrb_value self, void* p) {
  mrb_data_init(self, p, &ci->own_type);
}

// ---- calling a script method from C++ ----------------------------------------------------------------------------
namespace {
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

struct ArenaGuard {  // a host loop must not grow the GC arena without bound
  mrb_state* mrb;
  int ai;
  explicit ArenaGuard(mrb_state* m) : mrb(m), ai(mrb_gc_arena_save(m)) {}
  ~ArenaGuard() { mrb_gc_arena_restore(mrb, ai); }
};
}  // namespace

Value call_method(Impl* i, mrb_value self, const std::string& name, const mrb_value* argv, mrb_int argc) {
  ArenaGuard guard(i->mrb);
  MethodJob job = {self, mrb_intern_cstr(i->mrb, name.c_str()), argv, argc};
  mrb_bool err = FALSE;
  mrb_value r = mrb_protect_error(i->mrb, method_job_body, &job, &err);
  if (err) throw_for_exception(i, r);
  return make_value(i, r);
}

}  // namespace detail

// ---- Value --------------------------------------------------------------------------------------------------------
std::string Value::class_name() const {
  if (!impl_) detail::empty_value();
  return mrb_obj_classname(detail::state_of(impl_), v_);
}

std::string Value::inspect() const {
  if (!impl_) detail::empty_value();
  return detail::protected_string(impl_, v_, "inspect");
}

// ---- Context ------------------------------------------------------------------------------------------------------
Context::Context() : p_(new detail::Impl) {
  detail::Impl* i = p_.get();
  i->mrb = mrb_open();
  if (!i->mrb) throw Error("nfcpoly: mrb_open failed (out of memory)");
  mrb_state* mrb = i->mrb;
  mrb->ud = i;
  i->cxt = mrb_ccontext_new(mrb);
  i->cxt->capture_errors = TRUE;
  mrb_ccontext_filename(mrb, i->cxt, "snippet");
  i->roots = mrb_ary_new(mrb);
  mrb_gc_register(mrb, i->roots);
  mrb_ary_set(mrb, i->roots, 0, mrb_nil_value());
  RClass* mod = mrb_define_module(mrb, "NfcPoly");
  i->host_error = mrb_define_class_under(mrb, mod, "HostError", mrb_exc_get(mrb, "RuntimeError"));
}

Context::~Context() {}

mrb_state* Context::mrb() const { return p_->mrb; }

std::vector<std::string> Context::languages() { return std::vector<std::string>{"ruby"}; }

namespace {
struct EvalJob {
  detail::Impl* impl;
  std::string_view code;
};
mrb_value eval_body(mrb_state* mrb, void* p) {
  EvalJob* j = static_cast<EvalJob*>(p);
  j->impl->cxt->lineno = 1;
  mrb_value v = mrb_load_nstring_cxt(mrb, j->code.empty() ? "" : j->code.data(), j->code.size(), j->impl->cxt);
  if (mrb->exc) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));  // report through mrb_protect_error
  return v;
}
}  // namespace

Value Context::eval_value(std::string_view language, std::string_view code) {
  if (language != "ruby" && language != "mruby")
    throw UnsupportedLanguage("nfcpoly: unsupported language '" + std::string(language) + "' (available: ruby)");
  detail::Impl* i = p_.get();
  detail::ArenaGuard guard(i->mrb);
  EvalJob job = {i, code};
  mrb_bool err = FALSE;
  mrb_value r = mrb_protect_error(i->mrb, eval_body, &job, &err);
  if (err) detail::throw_for_exception(i, r);
  return detail::make_value(i, r);
}

}  // namespace nfcpoly
