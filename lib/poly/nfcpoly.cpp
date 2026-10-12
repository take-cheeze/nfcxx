// nfcpoly language-neutral core. See nfcpoly.hpp, nfcpoly_lang.hpp and docs/notes/poly.md.
#include "nfcpoly_lang.hpp"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>

namespace nfcpoly {
namespace detail {

namespace {

unsigned long g_serial = 0;  // script error objects handed to the host, numbered across all contexts

struct Registered {
  std::string name;
  LangFactory factory;
};
std::vector<Registered>& registry() {
  static std::vector<Registered> r;
  return r;
}
std::vector<std::pair<std::string, std::string>>& aliases() {  // alias -> canonical name
  static std::vector<std::pair<std::string, std::string>> a;
  return a;
}
std::set<Lang*>& live_langs() {
  static std::set<Lang*> s;
  return s;
}
std::map<const void*, std::string>& hints() {
  static std::map<const void*, std::string> m;
  return m;
}

bool ident_char(char c, bool first) {
  unsigned char u = static_cast<unsigned char>(c);
  return std::isalpha(u) || c == '_' || (!first && std::isdigit(u));
}

// The language a script value came from, if its interpreter is still running.
Lang* source_lang(const Var& v) {
  Lang* l = v.kind() == Var::Script ? v.handle()->lang : v.src();
  if (l && live_langs().count(l)) return l;
  return nullptr;
}

struct Event {  // everything declared to the context, replayed into each language when it starts
  enum Kind { Fn, Val, Variable, Class, Method, Prop, Ctor } kind;
  std::string name;
  Callable* c = nullptr;
  Callable* c2 = nullptr;
  ClassInfo* ci = nullptr;
  Var v;
};

void apply(Lang* l, const Event& e) {
  switch (e.kind) {
    case Event::Fn: l->define_fn(e.name, e.c); break;
    case Event::Val: l->define_value(e.name, e.v); break;
    case Event::Variable: l->define_variable(e.name, e.c, e.c2); break;
    case Event::Class: l->class_define(e.ci); break;
    case Event::Method: l->class_method(e.ci, e.name, e.c); break;
    case Event::Prop: l->class_prop(e.ci, e.name, e.c, e.c2); break;
    case Event::Ctor: l->class_ctor(e.ci, e.c); break;
  }
}

}  // namespace

struct Impl {
  std::map<const void*, ClassInfo*> classes;  // never freed: a Var that outlives the context still points at its class
  std::vector<std::unique_ptr<Callable>> callables;
  std::vector<Event> events;
  std::vector<std::pair<std::string, std::unique_ptr<Lang>>> langs;  // started interpreters, by canonical name
  Handle* handles = nullptr;  // every live Handle of this context
  ~Impl() {
    // Handles outlive the interpreters safely: they forget their script value, and only their memory remains.
    Handle* h = handles;
    handles = nullptr;
    while (h) {
      Handle* n = h->next;
      h->orphan();
      h->lang = nullptr;
      h->impl = nullptr;
      h->prev = h->next = nullptr;
      h = n;
    }
    langs.clear();  // closes the interpreters; the finalizers of script-owned objects run here
  }
  void record(Event e) {
    events.push_back(std::move(e));
    for (auto& l : langs) apply(l.second.get(), events.back());
  }
};

Lang::Lang(Impl* i) : impl(i) { live_langs().insert(this); }
Lang::~Lang() { live_langs().erase(this); }

Handle::Handle(Lang* l, Impl* i) : lang(l), impl(i) {
  next = i->handles;
  if (next) next->prev = this;
  i->handles = this;
}
Handle::~Handle() {
  if (!impl) return;
  if (prev) prev->next = next;
  else impl->handles = next;
  if (next) next->prev = prev;
}

LangRegistrar::LangRegistrar(const char* name, const char* alias1, const char* alias2, LangFactory factory) {
  registry().push_back(Registered{name, factory});
  aliases().push_back(std::make_pair(std::string(name), std::string(name)));
  if (alias1) aliases().push_back(std::make_pair(std::string(alias1), std::string(name)));
  if (alias2) aliases().push_back(std::make_pair(std::string(alias2), std::string(name)));
}

Impl* impl_of(Lang* l) { return l->impl; }

bool valid_global_name(const std::string& name) {
  if (name.empty() || !ident_char(name[0], true) || std::isupper(static_cast<unsigned char>(name[0]))) return false;
  for (std::size_t k = 1; k < name.size(); ++k)
    if (!ident_char(name[k], false)) return false;
  return true;
}

static void check_global_name(const std::string& name) {
  if (!valid_global_name(name))
    throw Error("nfcpoly: '" + name + "' is not a usable global name (a lower-case identifier)");
}

Lang* get_lang(Impl* impl, std::string_view language) {
  std::string canonical;
  for (auto& a : aliases())
    if (language == a.first) canonical = a.second;
  if (canonical.empty()) {
    std::string have;
    std::vector<std::string> names = nfcpoly::Context::languages();
    for (std::size_t k = 0; k < names.size(); ++k) have += (k ? ", " : "") + names[k];
    throw UnsupportedLanguage("nfcpoly: unsupported language '" + std::string(language) + "' (available: " + have + ")");
  }
  for (auto& l : impl->langs)
    if (l.first == canonical) return l.second.get();
  LangFactory factory = nullptr;
  for (auto& r : registry())
    if (r.name == canonical) factory = r.factory;
  std::unique_ptr<Lang> l = factory(impl);
  for (const Event& e : impl->events) apply(l.get(), e);
  Lang* raw = l.get();
  impl->langs.push_back(std::make_pair(canonical, std::move(l)));
  return raw;
}

[[noreturn]] void raise_script_error(Lang* l, const std::string& cls, const std::string& msg,
                                     std::vector<std::string> backtrace, bool syntax) {
  l->exc_serial = ++g_serial;
  if (syntax) throw SyntaxError(cls + ": " + msg);
  throw ScriptError(cls, msg, std::move(backtrace), l, l->exc_serial);
}

// ---- declarations -------------------------------------------------------------------------------------------------
ClassInfo* find_class(Impl* impl, const void* key) {
  auto it = impl->classes.find(key);
  return it == impl->classes.end() ? nullptr : it->second;
}

std::string class_name_hint(const void* key) {
  auto it = hints().find(key);
  return it == hints().end() ? std::string("a registered class") : it->second;
}

void declare_fn(Impl* impl, const std::string& name, std::unique_ptr<Callable> c) {
  check_global_name(name);
  Event e;
  e.kind = Event::Fn;
  e.name = name;
  e.c = c.get();
  impl->callables.push_back(std::move(c));
  impl->record(std::move(e));
}

void declare_value(Impl* impl, const std::string& name, const Var& v) {
  check_global_name(name);
  Event e;
  e.kind = Event::Val;
  e.name = name;
  e.v = v;
  impl->record(std::move(e));
}

void declare_variable(Impl* impl, const std::string& name, std::unique_ptr<Callable> get, std::unique_ptr<Callable> set) {
  check_global_name(name);
  Event e;
  e.kind = Event::Variable;
  e.name = name;
  e.c = get.get();
  e.c2 = set.get();
  impl->callables.push_back(std::move(get));
  if (set) impl->callables.push_back(std::move(set));
  impl->record(std::move(e));
}

ClassInfo* declare_class(Impl* impl, const void* key, const std::string& name) {
  if (name.empty() || !std::isupper(static_cast<unsigned char>(name[0])))
    throw Error("nfcpoly: '" + name + "' is not a script class name (a constant: upper-case first letter)");
  for (std::size_t k = 1; k < name.size(); ++k)
    if (!ident_char(name[k], false)) throw Error("nfcpoly: '" + name + "' is not a script class name");
  if (impl->classes.count(key)) throw Error("nfcpoly: this C++ class is already registered as " + impl->classes[key]->name);
  for (auto& kv : impl->classes)
    if (kv.second->name == name) throw Error("nfcpoly: the script class name " + name + " is already registered");
  ClassInfo* ci = new ClassInfo;
  ci->name = name;
  ci->key = key;
  impl->classes[key] = ci;
  hints()[key] = name;
  Event e;
  e.kind = Event::Class;
  e.ci = ci;
  impl->record(std::move(e));
  return ci;
}

void declare_method(Impl* impl, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> c) {
  if (name.empty()) throw Error("nfcpoly: empty method name");
  Event e;
  e.kind = Event::Method;
  e.ci = ci;
  e.name = name;
  e.c = c.get();
  ci->methods.push_back(std::make_pair(name, c.get()));
  impl->callables.push_back(std::move(c));
  impl->record(std::move(e));
}

void declare_prop(Impl* impl, ClassInfo* ci, const std::string& name, std::unique_ptr<Callable> get,
                  std::unique_ptr<Callable> set) {
  if (name.empty()) throw Error("nfcpoly: empty field name");
  Event e;
  e.kind = Event::Prop;
  e.ci = ci;
  e.name = name;
  e.c = get.get();
  e.c2 = set.get();
  ClassInfo::Prop p;
  p.name = name;
  p.get = get.get();
  p.set = set.get();
  ci->props.push_back(p);
  impl->callables.push_back(std::move(get));
  if (set) impl->callables.push_back(std::move(set));
  impl->record(std::move(e));
}

void declare_ctor(Impl* impl, ClassInfo* ci, std::unique_ptr<Callable> c) {
  Event e;
  e.kind = Event::Ctor;
  e.ci = ci;
  e.c = c.get();
  ci->ctor = c.get();
  impl->callables.push_back(std::move(c));
  impl->record(std::move(e));
}

// ---- evaluation and script values ----------------------------------------------------------------------------------
Var eval_in(Impl* impl, std::string_view language, std::string_view code) {
  Lang* l = get_lang(impl, language);
  return l->eval(code);
}

Var call_in(const Var& target, const std::string& method, const std::vector<Var>& args) {
  Lang* l = source_lang(target);
  if (!l) empty_value();
  return l->call(target, method, args);
}

Impl* impl_for(const Var& v) {
  Lang* l = source_lang(v);
  if (!l) empty_value();
  return l->impl;
}

Var deep(const Var& v) {
  if (v.kind() != Var::Script) return v;
  Lang* l = source_lang(v);
  return l ? l->to_var(v) : v;
}

std::string inspect_of(const Var& v) {
  Lang* l = source_lang(v);
  if (!l) return v.kind() == Var::Str ? v.s() : std::string(v.kind_name());
  return l->inspect(v);
}

std::string type_name_of(const Var& v) {
  if (v.kind() == Var::Obj) return v.ci()->name;
  Lang* l = source_lang(v);
  return l ? l->type_name(v) : std::string(v.kind_name());
}

bool is_array_value(const Var& v) {
  if (v.kind() != Var::Script) return false;
  Lang* l = source_lang(v);
  return l && l->is_array(v);
}

const char* Var::kind_name() const {
  switch (k_) {
    case Nil: return "nil";
    case Bool: return "boolean";
    case Int: return "integer";
    case Float: return "float";
    case Str: return "string";
    case Arr: return "array";
    case Obj: return "object";
    case Script: return "script value";
  }
  return "?";
}

static std::string got_name(const Var& v) {
  if (v.kind() == Var::Obj) return v.ci()->name;
  if (v.kind() == Var::Script) return type_name_of(v);
  return v.kind_name();
}

void conversion_error(const Var& v, const char* want) {
  throw ConversionError(std::string("expected ") + want + ", got " + got_name(v));
}
void range_error(const char* what) { throw ConversionError(what); }
void unregistered_class(const void* key) {
  throw ConversionError("nfcpoly: a C++ object of a class that is not registered (" + class_name_hint(key) +
                        ") crossed into the script without Context::def_class");
}
void empty_value() { throw Error("nfcpoly: the Value is empty or its context is gone"); }

}  // namespace detail

// ---- Context ------------------------------------------------------------------------------------------------------
Context::Context() : p_(new detail::Impl) {}
Context::~Context() {}

std::vector<std::string> Context::languages() {
  std::vector<std::string> names;
  for (auto& r : detail::registry()) names.push_back(r.name);
  std::sort(names.begin(), names.end());
  return names;
}

}  // namespace nfcpoly
