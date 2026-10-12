// nfcpoly "ast" backend: Lua-syntax scripts run by the nfcast engine (lib/ast), a self-specializing AST interpreter in C++.
// See docs/notes/poly.md and docs/notes/ast.md.
//
// The engine is C++, so a script error is a C++ exception (nfcast::Thrown) on the same exception runtime as the host's: it
// unwinds the C++ frames it crosses and runs their destructors, and a bound function's frame lets it pass (the trampoline
// rethrows it). The error values and the exception rules are the Lua backend's: a script error raised by the backend is a
// table {class=, message=} with a metatable whose __tostring gives "class: message"; a host exception that entered the
// script travels in the field `host`; error("text") raises a plain string, reported as class "LuaError".
#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <memory>
#include <set>

#include "nfcast.hpp"
#include "nfcpoly_ast.hpp"
#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

using nfcast::Args;
using nfcast::Rets;
using nfcast::Value;

struct AstLang;

// Everything the script can hold that is not engine data comes from here.
struct AstHostBase : nfcast::HostObject {
  enum Kind { Object, Exception } kind;
  explicit AstHostBase(Kind k) : kind(k) {}
};

struct AstObj : AstHostBase {  // an instance of a bound class
  ClassInfo* ci;
  void* p;
  Owned* own;
  AstObj(ClassInfo* c, void* ptr, Owned* o) : AstHostBase(Object), ci(c), p(ptr), own(o) {
    if (own) owned_ref(own);
  }
  ~AstObj() override {
    if (own) owned_unref(own);
  }
  const void* type_key() const override { return ci; }
  nfcast::HostMember* member(nfcast::State& S, nfcast::String* name) override;
  std::string describe() const override { return ci->name + " object"; }
  bool same_as(const HostObject* o) const override {
    if (o->type_key() != type_key()) return false;
    return static_cast<const AstObj*>(o)->p == p;
  }
};

struct HostExcBox : AstHostBase {  // a C++ exception travelling inside a script error
  std::exception_ptr ep;
  explicit HostExcBox(std::exception_ptr e) : AstHostBase(Exception), ep(std::move(e)) {}
  const void* type_key() const override { return &tag; }
  nfcast::HostMember* member(nfcast::State&, nfcast::String*) override { return nullptr; }
  std::string describe() const override { return "host exception"; }
  static const char tag;
};
const char HostExcBox::tag = 0;

struct AHandle : Handle {
  nfcast::State* S;
  int id;
  AHandle(Lang* l, Impl* i, nfcast::State* s, int pin) : Handle(l, i), S(s), id(pin) {}
  ~AHandle() override {
    if (lang && S) S->unpin(id);
  }
  void orphan() override { S = nullptr; }
};

struct LiveVar {
  Callable* get;
  Callable* set;
};

// What a trampoline raises once the C++ handlers have finished.
struct Pending {
  enum Kind { None, Existing, Plain, Host } kind = None;
  std::string cls, msg;
  std::exception_ptr host;
};

void run_callable(nfcast::State& S, Callable* c, const Value* self, Args a, Rets& r);
void fn_tramp(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);
void method_tramp(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);
void ctor_call(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);
void live_index(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);
void live_newindex(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);
void err_tostring(nfcast::State& S, Args a, Rets& r, nfcast::Native& self);

struct PropMember : nfcast::HostMember {
  ClassInfo* ci;
  ClassInfo::Prop prop;
  PropMember(ClassInfo* c, const ClassInfo::Prop& p) : ci(c), prop(p) {}
  Value get(nfcast::State& S, nfcast::HostObject* self) override {
    Value sv = Value::host(self);
    Rets r;
    Args none;
    none.v = nullptr;
    none.n = 0;
    run_callable(S, prop.get, &sv, none, r);
    return r.first();
  }
  void set(nfcast::State& S, nfcast::HostObject* self, const Value& v) override;
  void call(nfcast::State& S, nfcast::HostObject*, Args, Rets&) override {
    S.rt_error("attempt to call a field value");
  }
};

struct MethodMember : nfcast::HostMember {
  Callable* c;
  std::string name;
  MethodMember(Callable* callable, std::string n) : c(callable), name(std::move(n)) { is_method = true; }
  Value get(nfcast::State& S, nfcast::HostObject*) override {
    // obj.method as a value: a function taking the receiver first, as obj.method(obj, ...) in Lua
    return Value::function(S.new_native(method_tramp, S.keep_name(name), c));
  }
  void set(nfcast::State& S, nfcast::HostObject*, const Value&) override { S.rt_error("cannot assign to method '" + name + "'"); }
  void call(nfcast::State& S, nfcast::HostObject* self, Args a, Rets& r) override {
    Value sv = Value::host(self);
    run_callable(S, c, &sv, a, r);
  }
};

// ---- the language -----------------------------------------------------------------------------------------------------
struct AstLang : Lang {
  std::unique_ptr<nfcast::State> S;
  nfcast::Table* err_meta = nullptr;
  int err_meta_pin = -1;
  int last_err_pin = -1;  // the script error object the backend last handed to the host
  std::set<ClassInfo*> defined;
  std::map<std::pair<ClassInfo*, std::string>, std::unique_ptr<nfcast::HostMember>> members;
  std::map<std::string, LiveVar> live;
  bool live_installed = false;

  explicit AstLang(Impl* i) : Lang(i), S(new nfcast::State) {
    S->userdata = this;
    S->open_libs();
    err_meta = S->new_table();
    err_meta_pin = S->pin(Value::table(err_meta));
    err_meta->set_str(*S, S->str("__tostring"), Value::function(S->new_native(err_tostring, "error:tostring")));
  }
  ~AstLang() override {
    if (last_err_pin >= 0) S->unpin(last_err_pin);
    S.reset();  // finalizes the host objects the scripts still held
  }
  const char* name() const override { return "ast"; }

  // ---- values ----
  Var handle_of(const Value& v) {
    int id = S->pin(v);
    return Var::script(new AHandle(this, impl, S.get(), id));
  }

  static bool is_host_obj(const Value& v) { return v.t == nfcast::T_HOST && static_cast<AstHostBase*>(v.hostobj())->kind == AstHostBase::Object; }

  Var decode(const Value& v) {  // shallow
    Var r;
    switch (v.t) {
      case nfcast::T_NIL: break;
      case nfcast::T_FALSE: r = Var::boolean(false); break;
      case nfcast::T_TRUE: r = Var::boolean(true); break;
      case nfcast::T_INT: r = Var::integer(static_cast<long long>(v.i)); break;
      case nfcast::T_FLT: r = Var::real(v.d); break;
      case nfcast::T_STR: r = Var::string(std::string(v.s()->view())); break;
      case nfcast::T_HOST:
        if (is_host_obj(v)) {
          AstObj* o = static_cast<AstObj*>(v.hostobj());
          r = Var::object(o->ci, o->p, o->own);
        } else {
          r = handle_of(v);
        }
        break;
      default: r = handle_of(v); break;
    }
    r.set_src(this);
    return r;
  }

  Value push(const Var& v) {
    switch (v.kind()) {
      case Var::Nil: return Value();
      case Var::Bool: return Value::boolean(v.b());
      case Var::Int: return Value::integer(static_cast<std::int64_t>(v.i()));
      case Var::Float: return Value::number(v.d());
      case Var::Str: return S->strv(v.s());
      case Var::Arr: {
        nfcast::Table* t = S->new_table(static_cast<std::uint32_t>(v.a().size()), 0);
        Value tv = Value::table(t);
        std::int64_t k = 1;
        for (const Var& e : v.a()) {
          Value ev = push(e);  // allocation never collects, so t stays valid while it is filled
          t->set_int(*S, k++, ev);
        }
        return tv;
      }
      case Var::Obj: {
        if (defined.find(v.ci()) == defined.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in ast");
        return Value::host(S->new_host<AstObj>(v.ci(), v.ptr(), v.owned()));
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) return S->pinned(static_cast<AHandle*>(h)->id);
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to ast");
        return push(d);
      }
    }
    return Value();
  }

  bool table_is_array(nfcast::Table* t) {
    std::int64_t n = t->length();
    std::int64_t count = 0;
    Value k, v;
    while (t->next(*S, k, v)) {
      if (k.t != nfcast::T_INT || k.i < 1 || k.i > n) return false;
      ++count;
    }
    return count == n;
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    std::string err;
    nfcast::Closure* cl = S->load("return " + std::string(code), "snippet", &err);  // a single expression returns its value
    if (!cl) {
      cl = S->load(code, "snippet", &err);
      if (!cl) raise_script_error(this, "SyntaxError", err, std::vector<std::string>(), true);
    }
    Rets out;
    try {
      S->call(Value::function(cl), nullptr, 0, out);
    } catch (nfcast::Thrown& t) {
      throw_for_error(t);
    }
    return decode(out.first());
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    Value tv = S->pinned(static_cast<AHandle*>(v.handle())->id);
    if (tv.t != nfcast::T_TAB || !table_is_array(tv.tab())) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    std::vector<Var> out;
    std::int64_t n = tv.tab()->length();
    for (std::int64_t k = 1; k <= n; ++k) out.push_back(deep_var(decode(tv.tab()->get_int(k)), depth + 1));
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    Value tv = push(target);
    std::vector<Value> argv;
    Value fn = tv;
    try {
      if (!method.empty()) {
        fn = S->index(tv, S->strv(method));
        if (fn.is_nil()) raise_script_error(this, "NoMethodError", "no method '" + method + "'", std::vector<std::string>(), false);
        argv.push_back(tv);
      }
      for (const Var& a : args) argv.push_back(push(a));
      Rets out;
      S->call(fn, argv.data(), static_cast<int>(argv.size()), out);
      return decode(out.first());
    } catch (nfcast::Thrown& t) {
      throw_for_error(t);
    }
  }

  std::string inspect(const Var& v) override {
    try {
      return S->tostring(push(v));
    } catch (nfcast::Thrown&) {
      return type_name(v);
    }
  }

  std::string type_name(const Var& v) override {
    Value x = push(v);
    if (x.t == nfcast::T_INT) return "integer";
    if (x.t == nfcast::T_FLT) return "float";
    return nfcast::State::type_name(x);
  }

  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    Value x = S->pinned(static_cast<AHandle*>(v.handle())->id);
    return x.t == nfcast::T_TAB && table_is_array(x.tab());
  }

  // ---- declarations ----
  void define_fn(const std::string& name, Callable* c) override {
    S->globals->set_str(*S, S->str(name), Value::function(S->new_native(fn_tramp, S->keep_name(name), c)));
  }
  void define_value(const std::string& name, const Var& v) override { S->globals->set_str(*S, S->str(name), push(v)); }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    live[name] = LiveVar{get, set};
    if (live_installed) return;
    live_installed = true;
    nfcast::Table* mt = S->new_table();
    mt->set_str(*S, S->str("__index"), Value::function(S->new_native(live_index, "live:index")));
    mt->set_str(*S, S->str("__newindex"), Value::function(S->new_native(live_newindex, "live:newindex")));
    S->globals->meta = mt;
  }
  void class_define(ClassInfo* ci) override {
    defined.insert(ci);
    S->globals->set_str(*S, S->str(ci->name), Value::table(S->new_table()));  // the class table: Name.new(...) and Name(...)
  }
  void class_method(ClassInfo*, const std::string&, Callable*) override {}  // looked up in ClassInfo on each first access
  void class_prop(ClassInfo*, const std::string&, Callable*, Callable*) override {}
  void class_ctor(ClassInfo* ci, Callable* c) override {
    Value ct = S->globals->get_str(S->str(ci->name));
    nfcast::Table* cls = ct.tab();
    cls->set_str(*S, S->str("new"), Value::function(S->new_native(fn_tramp, S->keep_name(ci->name + ".new"), c)));
    nfcast::Table* mt = S->new_table();
    mt->set_str(*S, S->str("__call"), Value::function(S->new_native(ctor_call, S->keep_name(ci->name), c)));
    cls->meta = mt;
  }

  nfcast::HostMember* find_member(ClassInfo* ci, const std::string& name) {
    auto key = std::make_pair(ci, name);
    auto it = members.find(key);
    if (it != members.end()) return it->second.get();
    std::unique_ptr<nfcast::HostMember> m;
    for (const ClassInfo::Prop& p : ci->props)
      if (p.name == name) m.reset(new PropMember(ci, p));
    if (!m)
      for (auto& me : ci->methods)
        if (me.first == name) m.reset(new MethodMember(me.second, ci->name + "." + name));
    if (!m) return nullptr;  // not remembered: the class may still gain members
    nfcast::HostMember* raw = m.get();
    members[key] = std::move(m);
    return raw;
  }

  // ---- errors ----
  Value make_error(const std::string& cls, const std::string& msg) {
    nfcast::Table* t = S->new_table(0, 3);
    t->set_str(*S, S->str("class"), S->strv(cls));
    t->set_str(*S, S->str("message"), S->strv(msg));
    t->meta = err_meta;
    return Value::table(t);
  }

  bool is_error_table(const Value& v) const { return v.t == nfcast::T_TAB && v.tab()->meta == err_meta; }

  // The host side of a script error: the original C++ exception when the script carried one out unrescued, else ScriptError.
  [[noreturn]] void throw_for_error(nfcast::Thrown& t) {
    std::string cls = "LuaError", msg;
    std::exception_ptr host;
    Value ev = t.v;
    if (is_error_table(ev)) {
      Value c = ev.tab()->get_str(S->str("class"));
      if (c.t == nfcast::T_STR) cls = std::string(c.s()->view());
      Value m = ev.tab()->get_str(S->str("message"));
      if (m.t == nfcast::T_STR) msg = std::string(m.s()->view());
      Value h = ev.tab()->get_str(S->str("host"));
      if (h.t == nfcast::T_HOST && static_cast<AstHostBase*>(h.hostobj())->kind == AstHostBase::Exception)
        host = static_cast<HostExcBox*>(h.hostobj())->ep;
    } else if (ev.t == nfcast::T_STR) {
      msg = std::string(ev.s()->view());
    } else {
      try {
        msg = S->tostring(ev);
      } catch (nfcast::Thrown&) {
        msg = "(error object)";
      }
    }
    if (host) std::rethrow_exception(host);
    if (last_err_pin >= 0) S->unpin(last_err_pin);
    last_err_pin = S->pin(ev);  // so that a trampoline can raise this very value again
    raise_script_error(this, cls, msg, t.trace, false);
  }
};

AstLang* lang_of(nfcast::State& S) { return static_cast<AstLang*>(S.userdata); }

nfcast::HostMember* AstObj::member(nfcast::State& S, nfcast::String* name) { return lang_of(S)->find_member(ci, std::string(name->view())); }

[[noreturn]] void raise_error(nfcast::State& S, const std::string& cls, const std::string& msg) {
  S.error(lang_of(S)->make_error(cls, msg));
  std::abort();  // not reached: error throws
}

[[noreturn]] void raise_pending(nfcast::State& S, Pending& p) {
  AstLang* lang = lang_of(S);
  if (p.kind == Pending::Existing) S.error(S.pinned(lang->last_err_pin));
  if (p.kind == Pending::Host) {
    Value err = lang->make_error("NfcPoly::HostError", p.msg);
    err.tab()->set_str(S, S.str("host"), Value::host(S.new_host<HostExcBox>(p.host)));
    S.error(err);
  }
  raise_error(S, p.cls, p.msg);
}

void PropMember::set(nfcast::State& S, nfcast::HostObject* self, const Value& v) {
  if (!prop.set) raise_error(S, "AttributeError", "field " + prop.name + " of " + ci->name + " is read-only");
  Value sv = Value::host(self);
  Value args1[1] = {v};
  Args a;
  a.v = args1;
  a.n = 1;
  Rets r;
  run_callable(S, prop.set, &sv, a, r);
}

// Calls C with the arguments (and, for a method or accessor, the receiver) and pushes its result. A C++ exception becomes a
// script error, raised after the handlers have finished.
void run_callable(nfcast::State& S, Callable* c, const Value* self, Args a, Rets& r) {
  AstLang* lang = lang_of(S);
  if (!arity_fits(c, a.n)) raise_error(S, "ArgumentError", arity_message(c, a.n));
  Pending pend;
  try {
    std::vector<Var> args;
    args.reserve(static_cast<std::size_t>(a.n));
    for (int k = 0; k < a.n; ++k) args.push_back(lang->decode(a.v[k]));
    arity_pad(c, args);
    Var selfv;
    const Var* sp = nullptr;
    if (self) {
      selfv = lang->decode(*self);
      sp = &selfv;
    }
    Var res = c->invoke(sp, args.data());
    r.push(lang->push(res));
    return;
  } catch (const nfcast::Thrown&) {
    throw;  // a script error passing through on its way to a pcall or to the host
  } catch (const ScriptError& e) {
    if (e.owner() == lang && e.serial() == lang->exc_serial) {
      pend.kind = Pending::Existing;  // the script error this came from: raise that very value again
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
  raise_pending(S, pend);
}

void fn_tramp(nfcast::State& S, Args a, Rets& r, nfcast::Native& self) {
  run_callable(S, static_cast<Callable*>(self.data), nullptr, a, r);
}

void method_tramp(nfcast::State& S, Args a, Rets& r, nfcast::Native& self) {  // obj.method(obj, args...)
  Callable* c = static_cast<Callable*>(self.data);
  if (a.n < 1) raise_error(S, "ArgumentError", "wrong number of arguments (given 0, expected receiver first)");
  Value sv = a.v[0];
  Args rest;
  rest.v = a.v + 1;
  rest.n = a.n - 1;
  run_callable(S, c, &sv, rest, r);
}

void ctor_call(nfcast::State& S, Args a, Rets& r, nfcast::Native& self) {  // Name(...): the class table is the first argument
  Args rest;
  rest.v = a.v + 1;
  rest.n = a.n > 0 ? a.n - 1 : 0;
  run_callable(S, static_cast<Callable*>(self.data), nullptr, rest, r);
}

void live_index(nfcast::State& S, Args a, Rets& r, nfcast::Native&) {  // (_G, key): a bound variable reads live
  AstLang* lang = lang_of(S);
  if (a.n >= 2 && a.v[1].t == nfcast::T_STR) {
    auto it = lang->live.find(std::string(a.v[1].s()->view()));
    if (it != lang->live.end()) {
      Args none;
      none.v = nullptr;
      none.n = 0;
      run_callable(S, it->second.get, nullptr, none, r);
      return;
    }
  }
  r.push(Value());
}

void live_newindex(nfcast::State& S, Args a, Rets&, nfcast::Native&) {  // (_G, key, value): a bound variable writes through
  AstLang* lang = lang_of(S);
  if (a.n >= 3 && a.v[1].t == nfcast::T_STR) {
    auto it = lang->live.find(std::string(a.v[1].s()->view()));
    if (it != lang->live.end()) {
      if (!it->second.set) raise_error(S, "NameError", "variable " + std::string(a.v[1].s()->view()) + " is read-only");
      Args one;
      one.v = a.v + 2;
      one.n = 1;
      Rets r;
      run_callable(S, it->second.set, nullptr, one, r);
      return;
    }
  }
  if (a.n >= 3) {
    if (a.v[1].is_nil()) S.rt_error("table index is nil");
    S.globals->set(S, a.v[1], a.v[2]);  // an ordinary global
  }
}

void err_tostring(nfcast::State& S, Args a, Rets& r, nfcast::Native&) {
  Value t = a[0];
  if (t.t != nfcast::T_TAB) {
    r.push(S.strv("?"));
    return;
  }
  Value c = t.tab()->get_str(S.str("class")), m = t.tab()->get_str(S.str("message"));
  r.push(S.strv(S.tostring(c) + ": " + S.tostring(m)));
}

std::unique_ptr<Lang> make_ast(Impl* impl) { return std::unique_ptr<Lang>(new AstLang(impl)); }
LangRegistrar registrar("ast", "nfcast", nullptr, &make_ast);

}  // namespace
}  // namespace detail

nfcast::State& ast_state(Context& ctx) { return *static_cast<detail::AstLang*>(detail::get_lang(ctx.impl(), "ast"))->S; }

nfcast::Value ast_value(const Value& v) {
  const detail::Var& var = v.var();
  detail::Lang* l = var.kind() == detail::Var::Script ? var.handle()->lang : var.src();
  if (!l) throw Error("nfcpoly: the Value has no live interpreter");
  if (std::strcmp(l->name(), "ast") != 0) throw Error("nfcpoly: ast_value of a value from another language");
  return static_cast<detail::AstLang*>(l)->push(var);
}

}  // namespace nfcpoly
