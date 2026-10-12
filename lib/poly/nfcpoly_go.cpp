// nfcpoly Go backend: Go source evaluated by yaegi (a Go interpreter written in Go), built into a cgo shared library
// (lib/poly/go, scripts/setup-poly-go.sh). See docs/notes/poly.md, "Go".
//
// Go is statically typed, so a bound function cannot be a function of "some arguments": the script-side function is
// written down in Go with the C++ parameter and result types (Callable::signature) and defined in the interpreter as
// generated Go source. A registered class becomes a Go struct type holding a *nfc.Obj with typed methods, field
// accessors and a constructor NewName. The wrapper bodies call back into the host through nfc.Call, one callback per
// bound call.
//
// Exceptions: a C++ exception must never unwind through Go frames. The callback the library calls (host_cb) catches
// everything the Callable throws and returns a status; the Go side turns it into a Go panic with a typed error value that
// script code can recover(). Where eval or call returns to C++, a panic nothing recovered becomes ScriptError, a compile
// error SyntaxError, and a panic that carries a host exception is rethrown as that very exception (the std::exception_ptr
// stays here, keyed by a number the Go value carries).
//
// Threads: the Go runtime runs the script's goroutines on threads of its own. A callback that arrives on a thread other
// than the one that entered the interpreter is refused before it touches any host state.
#include "nfcpoly_go.hpp"

#include <pthread.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <unordered_map>

#include "go/nfcgo.h"
#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

// ---- the wire format (go/codec.go) -----------------------------------------------------------------------------------
enum : unsigned char { tNil, tFalse, tTrue, tInt, tFloat, tStr, tArr, tObj, tHandle };
enum { opEval = 1, opDecl, opCall, opArray, opInspect, opType, opIsArray };
enum { stOK = 0, stScript, stSyntax, stHost, stInternal };  // what nfcgo_do returns
enum { hostOK = 0, hostException, hostType, hostRepanic, hostPlain, hostThread };  // what host_cb returns
const unsigned long long kExcBit = 1ULL << 63;  // an id with this bit is an exception, else an object

struct Wr {
  std::string b;
  void u8(unsigned char v) { b.push_back(static_cast<char>(v)); }
  void u32(unsigned v) {
    for (int k = 0; k < 4; ++k) b.push_back(static_cast<char>((v >> (8 * k)) & 0xff));
  }
  void u64(unsigned long long v) {
    for (int k = 0; k < 8; ++k) b.push_back(static_cast<char>((v >> (8 * k)) & 0xff));
  }
  void f64(double d) {
    unsigned long long u;
    std::memcpy(&u, &d, 8);
    u64(u);
  }
  void str(const std::string& s) {
    u32(static_cast<unsigned>(s.size()));
    b.append(s);
  }
};

struct Rd {
  const unsigned char* p;
  const unsigned char* e;
  bool bad = false;
  Rd(const char* d, std::size_t n) : p(reinterpret_cast<const unsigned char*>(d)), e(p + n) {}
  bool need(std::size_t n) {
    if (bad || static_cast<std::size_t>(e - p) < n) {
      bad = true;
      return false;
    }
    return true;
  }
  unsigned char u8() {
    if (!need(1)) return 0;
    return *p++;
  }
  unsigned u32() {
    if (!need(4)) return 0;
    unsigned v = 0;
    for (int k = 0; k < 4; ++k) v |= static_cast<unsigned>(p[k]) << (8 * k);
    p += 4;
    return v;
  }
  unsigned long long u64() {
    if (!need(8)) return 0;
    unsigned long long v = 0;
    for (int k = 0; k < 8; ++k) v |= static_cast<unsigned long long>(p[k]) << (8 * k);
    p += 8;
    return v;
  }
  double f64() {
    unsigned long long u = u64();
    double d;
    std::memcpy(&d, &u, 8);
    return d;
  }
  std::string str() {
    unsigned n = u32();
    if (!need(n)) return std::string();
    std::string s(reinterpret_cast<const char*>(p), n);
    p += n;
    return s;
  }
};

// ---- generated Go source: names, types, literals -----------------------------------------------------------------
std::string go_name(const std::string& s) {  // len2 -> Len2, to_s -> ToS
  std::string out;
  bool up = true;
  for (char c : s) {
    if (c == '_') {
      up = true;
      continue;
    }
    out.push_back(up && c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c);
    up = false;
  }
  return out;
}

bool go_ident(const std::string& s) {
  if (s.empty() || (s[0] >= '0' && s[0] <= '9')) return false;
  for (char c : s)
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')) return false;
  return true;
}

std::string quote(const std::string& s) {
  static const char* hex = "0123456789abcdef";
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(static_cast<char>(c));
    } else if (c < 0x20 || c >= 0x7f) {
      out += "\\x";
      out.push_back(hex[c >> 4]);
      out.push_back(hex[c & 15]);
    } else {
      out.push_back(static_cast<char>(c));
    }
  }
  return out + "\"";
}

std::string float_literal(double d) {
  if (d != d) return "math.NaN()";
  if (d > 1.79e308) return "math.Inf(1)";
  if (d < -1.79e308) return "math.Inf(-1)";
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.17g", d);
  return buf;
}

struct GoLang;

struct GHandle : Handle {
  unsigned long long id;
  GHandle(Lang* l, Impl* i, unsigned long long h) : Handle(l, i), id(h) {}
  ~GHandle() override;
  void orphan() override {}
};

// Who may call back: the thread that is inside a call into the interpreter. Shared with host_cb, which runs on whatever
// thread Go happens to call it from.
struct Slot {
  std::atomic<unsigned long> owner{0};
  GoLang* lang = nullptr;  // null once the language is gone; guarded by g_mu
};

std::mutex g_mu;
std::map<long long, std::shared_ptr<Slot>>& g_slots() {
  static std::map<long long, std::shared_ptr<Slot>> m;
  return m;
}

int host_cb(long long gid, int op, const char* in, std::size_t n, char** out, std::size_t* outn);

struct ReadOnlyWrite {
  std::string name;
};

struct Item {  // a declaration waiting to be defined in the interpreter
  enum Kind { Fn, Val, Variable, Class, Method, Prop, Ctor } kind;
  std::string name;
  Callable* c = nullptr;
  Callable* c2 = nullptr;
  ClassInfo* ci = nullptr;
  Var v;
};

struct Live {
  std::string name;
  Callable* get;
  Callable* set;
  char kind;
};

struct Gen {  // the pieces of one declaration message
  std::string src;
  std::vector<std::pair<unsigned, std::string>> sigs;
  std::vector<Live> lives;
  std::vector<std::pair<unsigned, std::string>> wraps;
};

struct GoLang : Lang {
  long long gid = 0;
  std::shared_ptr<Slot> slot;
  std::vector<Callable*> callables;                 // id - 1
  std::map<Callable*, unsigned> callable_ids;
  std::vector<ClassInfo*> classes;                  // id - 1
  std::map<ClassInfo*, unsigned> class_ids;
  std::unordered_map<unsigned long long, Var> objs;  // host objects the script holds, by the id its wrapper carries
  unsigned long long next_obj = 0, next_exc = 0;
  std::unordered_map<unsigned long long, std::exception_ptr> excs;  // host exceptions the script holds
  std::vector<Live> lives;                          // the variables defined in the interpreter so far
  std::vector<Item> pending;
  bool started = false;
  std::vector<unsigned long long> drop_handles;     // handles to tell Go about at the next boundary

  explicit GoLang(Impl* i) : Lang(i) {
    static bool host_set = false;
    if (!host_set) {
      nfcgo_set_host(reinterpret_cast<void*>(&host_cb));
      host_set = true;
    }
    gid = nfcgo_open();
    if (gid == 0) throw Error("nfcpoly: the Go interpreter could not be started");
    slot = std::make_shared<Slot>();
    slot->lang = this;
    std::lock_guard<std::mutex> g(g_mu);
    g_slots()[gid] = slot;
  }
  ~GoLang() override {
    {
      std::lock_guard<std::mutex> g(g_mu);
      slot->lang = nullptr;
      g_slots().erase(gid);
    }
    nfcgo_close(gid);
    objs.clear();  // the host objects the script still owned are released here, on the host thread
    excs.clear();
  }
  const char* name() const override { return "go"; }

  // ---- crossing into Go ----
  struct Enter {  // marks this thread as the one inside the interpreter, so that callbacks arriving on it are served
    GoLang* l;
    unsigned long prev;
    explicit Enter(GoLang* g) : l(g), prev(g->slot->owner.exchange(static_cast<unsigned long>(pthread_self()))) {}
    ~Enter() { l->slot->owner.store(prev); }
  };

  struct Reply {
    int status = stInternal;
    std::string data;
    std::exception_ptr write_error;
    std::string read_only;
  };

  void put_meta(Wr& w) {
    Wr live;
    put_live(live);  // may throw (a getter of the host): before the handles to drop are taken off the list
    w.u32(static_cast<unsigned>(drop_handles.size()));
    for (unsigned long long h : drop_handles) w.u64(h);
    drop_handles.clear();
    w.b.append(live.b);
  }
  void put_live(Wr& w) {
    w.u32(static_cast<unsigned>(lives.size()));
    for (const Live& lv : lives) encode(w, lv.get->invoke(nullptr, nullptr));
  }

  Reply go(int op, const std::string& msg) {
    char* out = nullptr;
    std::size_t outn = 0;
    int st = nfcgo_do(gid, op, const_cast<char*>(msg.data()), msg.size(), &out, &outn);
    Reply r;
    r.status = st;
    if (out) {
      r.data.assign(out, outn);
      std::free(out);
    }
    return r;
  }

  // The part of a reply that comes before the payload: variables the script wrote, host objects whose wrappers died.
  Rd read_meta(Reply& r) {
    Rd rd(r.data.data(), r.data.size());
    unsigned nw = rd.u32();
    for (unsigned k = 0; k < nw && !rd.bad; ++k) {
      unsigned idx = rd.u32();
      Var v = decode(rd);
      if (idx >= lives.size()) continue;
      Live& lv = lives[idx];
      if (!lv.set) {
        if (r.read_only.empty()) r.read_only = lv.name;
        continue;
      }
      try {
        lv.set->invoke(nullptr, &v);
      } catch (...) {
        if (!r.write_error) r.write_error = std::current_exception();
      }
    }
    unsigned nr = rd.u32();
    for (unsigned k = 0; k < nr && !rd.bad; ++k) release(rd.u64());
    return rd;
  }

  void release(unsigned long long id) {
    if (id & kExcBit) excs.erase(id & ~kExcBit);
    else objs.erase(id);
  }

  // The result of an operation that runs script code: the value, or the host's version of the script's failure.
  Var finish(Reply& r) {
    Rd rd = read_meta(r);
    return finish_with(r, rd);
  }
  Var finish_with(Reply& r, Rd& rd) {
    if (r.status == stOK) {
      if (r.write_error) std::rethrow_exception(r.write_error);
      if (!r.read_only.empty())
        raise_script_error(this, "ReadOnlyError", "variable " + r.read_only + " is read-only", std::vector<std::string>(), false);
      Var v = decode(rd);
      if (rd.bad) throw Error("nfcpoly: malformed reply from the Go interpreter");
      return v;
    }
    switch (r.status) {
      case stScript: {
        std::string cls = rd.str(), msg = rd.str();
        std::vector<std::string> bt;
        unsigned n = rd.u32();
        for (unsigned k = 0; k < n && !rd.bad; ++k) bt.push_back(rd.str());
        raise_script_error(this, cls, msg, std::move(bt), false);
      }
      case stSyntax: raise_script_error(this, "SyntaxError", rd.str(), std::vector<std::string>(), true);
      case stHost: {
        unsigned long long id = rd.u64();
        auto it = excs.find(id & ~kExcBit);
        if (it == excs.end()) throw Error("nfcpoly: a host exception that is no longer held: " + rd.str());
        std::exception_ptr ep = it->second;  // stays in the table: the script may still hold the error value
        std::rethrow_exception(ep);
      }
      default: break;
    }
    throw Error("nfcpoly: go: " + rd.str());
  }

  // ---- values ----
  void encode(Wr& w, const Var& v) {
    switch (v.kind()) {
      case Var::Nil: w.u8(tNil); break;
      case Var::Bool: w.u8(v.b() ? tTrue : tFalse); break;
      case Var::Int: w.u8(tInt); w.u64(static_cast<unsigned long long>(v.i())); break;
      case Var::Float: w.u8(tFloat); w.f64(v.d()); break;
      case Var::Str: w.u8(tStr); w.str(v.s()); break;
      case Var::Arr:
        w.u8(tArr);
        w.u32(static_cast<unsigned>(v.a().size()));
        for (const Var& e : v.a()) encode(w, e);
        break;
      case Var::Obj: {
        auto it = class_ids.find(v.ci());
        if (it == class_ids.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in go");
        unsigned long long id = ++next_obj;
        objs.emplace(id, v);
        w.u8(tObj);
        w.u64(id);
        w.u32(it->second);
        break;
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) {
          w.u8(tHandle);
          w.u64(static_cast<GHandle*>(h)->id);
          break;
        }
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to go");
        encode(w, d);
        break;
      }
    }
  }

  Var decode(Rd& rd) {
    Var r;
    switch (rd.u8()) {
      case tNil: break;
      case tFalse: r = Var::boolean(false); break;
      case tTrue: r = Var::boolean(true); break;
      case tInt: r = Var::integer(static_cast<long long>(rd.u64())); break;
      case tFloat: r = Var::real(rd.f64()); break;
      case tStr: r = Var::string(rd.str()); break;
      case tArr: {
        unsigned n = rd.u32();
        std::vector<Var> out;
        for (unsigned k = 0; k < n && !rd.bad; ++k) out.push_back(decode(rd));
        r = Var::array(std::move(out));
        break;
      }
      case tObj: {
        unsigned long long id = rd.u64();
        rd.u32();
        auto it = objs.find(id);
        if (it == objs.end()) throw ConversionError("nfcpoly: a host object that the script used was already released");
        r = it->second;
        break;
      }
      case tHandle: r = Var::script(new GHandle(this, impl, rd.u64())); break;
      default: rd.bad = true; break;
    }
    r.set_src(this);
    return r;
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    start();
    Enter e(this);
    Wr w;
    put_meta(w);
    w.str(std::string(code));
    Reply r = go(opEval, w.b);
    return finish(r);
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    if (!is_array(v)) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    start();
    Enter e(this);
    Wr w;
    encode(w, v);
    Reply r = go(opArray, w.b);
    Rd rd = read_meta(r);
    if (r.status != stOK) finish_with(r, rd);
    unsigned n = rd.u32();
    std::vector<Var> out;
    for (unsigned k = 0; k < n && !rd.bad; ++k) out.push_back(deep_var(decode(rd), depth + 1));
    Var res = Var::array(std::move(out));
    res.set_src(this);
    return res;
  }

  std::string text_op(int op, const Var& v) {
    start();
    Enter e(this);
    Wr w;
    encode(w, v);
    Reply r = go(op, w.b);
    Rd rd = read_meta(r);
    if (r.status != stOK) return std::string();
    return rd.str();
  }
  std::string inspect(const Var& v) override {
    if (v.kind() == Var::Obj) return "<" + v.ci()->name + " object>";
    return text_op(opInspect, v);
  }
  std::string type_name(const Var& v) override { return text_op(opType, v); }
  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    start();
    Enter e(this);
    Wr w;
    encode(w, v);
    Reply r = go(opIsArray, w.b);
    Rd rd = read_meta(r);
    return r.status == stOK && rd.u8() == 1;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    if (target.kind() == Var::Obj) return call_object(target, method, args);
    start();
    Enter e(this);
    Wr w;
    put_meta(w);
    encode(w, target);
    w.str(method);
    w.u32(static_cast<unsigned>(args.size()));
    for (const Var& a : args) encode(w, a);
    Reply r = go(opCall, w.b);
    return finish(r);
  }

  // A method of a host object, by its Go name (Len2) or its registered name (len2); fields as X() and SetX(v).
  Var call_object(const Var& target, const std::string& method, const std::vector<Var>& args) {
    ClassInfo* ci = target.ci();
    Callable* c = nullptr;
    for (auto& m : ci->methods)
      if (m.first == method || go_name(m.first) == method) c = m.second;
    if (!c) {
      for (const ClassInfo::Prop& p : ci->props) {
        if (go_name(p.name) == method || p.name == method) c = p.get;
        else if (p.set && method == "Set" + go_name(p.name)) c = p.set;
      }
    }
    if (!c)
      raise_script_error(this, "NoMethodError", "undefined method '" + method + "' for " + ci->name, std::vector<std::string>(), false);
    if (!arity_fits(c, static_cast<long>(args.size())))
      raise_script_error(this, "ArgumentError", arity_message(c, static_cast<long>(args.size())), std::vector<std::string>(), false);
    std::vector<Var> padded = args;
    arity_pad(c, padded);
    return c->invoke(&target, padded.data());
  }

  // ---- declarations ----
  // Definitions are collected until the first use of the interpreter and defined then in one message, classes first, so that
  // a function may be bound before the class it mentions is registered. Once started, each declaration is defined at once;
  // one that mentions a class that is not registered yet waits for it.
  void add(Item it) {
    pending.push_back(std::move(it));
    if (started) flush();
  }
  void start() {
    if (started) return;
    started = true;
    flush();
  }

  void define_fn(const std::string& name, Callable* c) override {
    Item it{Item::Fn, name};
    it.c = c;
    add(std::move(it));
  }
  void define_value(const std::string& name, const Var& v) override {
    Item it{Item::Val, name};
    it.v = v;
    add(std::move(it));
  }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    Item it{Item::Variable, name};
    it.c = get;
    it.c2 = set;
    add(std::move(it));
  }
  void class_define(ClassInfo* ci) override {
    Item it{Item::Class, ci->name};
    it.ci = ci;
    add(std::move(it));
  }
  void class_method(ClassInfo* ci, const std::string& name, Callable* c) override {
    Item it{Item::Method, name};
    it.ci = ci;
    it.c = c;
    add(std::move(it));
  }
  void class_prop(ClassInfo* ci, const std::string& name, Callable* get, Callable* set) override {
    Item it{Item::Prop, name};
    it.ci = ci;
    it.c = get;
    it.c2 = set;
    add(std::move(it));
  }
  void class_ctor(ClassInfo* ci, Callable* c) override {
    Item it{Item::Ctor, ci->name};
    it.ci = ci;
    it.c = c;
    add(std::move(it));
  }

  // ---- generated source ----
  struct Unresolved {};  // a class the declaration mentions is not defined (yet)

  unsigned class_id(const void* key) {
    ClassInfo* ci = find_class(impl, key);
    auto it = ci ? class_ids.find(ci) : class_ids.end();
    if (it == class_ids.end()) throw Unresolved();
    return it->second;
  }
  const std::string& class_name_of(unsigned id) const { return classes[id - 1]->name; }

  // The Go type a script sees (BRIDGE false) or the type the bridge passes (BRIDGE true: a class is *nfc.Obj).
  std::string gotype(const TypeDesc& d, bool bridge) {
    switch (d.kind) {
      case TypeDesc::Void: return "";
      case TypeDesc::Bool: return "bool";
      case TypeDesc::Int: return "int";
      case TypeDesc::UInt: return "uint";
      case TypeDesc::Float: return "float64";
      case TypeDesc::Str: return "string";
      case TypeDesc::Any: return "any";
      case TypeDesc::Class: return bridge ? "*nfc.Obj" : "*" + class_name_of(class_id(d.key));
      case TypeDesc::Vec: return "[]" + gotype(d.elem[0], bridge);
      case TypeDesc::Opt:
        if (d.elem[0].kind == TypeDesc::Class) return gotype(d.elem[0], bridge);
        return "*" + gotype(d.elem[0], bridge);
    }
    return "any";
  }
  static bool has_class(const TypeDesc& d) {
    if (d.kind == TypeDesc::Class) return true;
    return (d.kind == TypeDesc::Vec || d.kind == TypeDesc::Opt) && has_class(d.elem[0]);
  }
  // EXPR (a script value) as the bridge's value, and back.
  std::string conv(const std::string& e, const TypeDesc& d, bool to_host) {
    if (!has_class(d)) return e;
    switch (d.kind) {
      case TypeDesc::Class: {
        const std::string& n = class_name_of(class_id(d.key));
        return (to_host ? "_nfc_h_" : "_nfc_w_") + n + "(" + e + ")";
      }
      case TypeDesc::Vec: {
        std::string from = gotype(d, !to_host), to = gotype(d, to_host);
        return "func(xs " + from + ") " + to + " { r := make(" + to + ", len(xs)); for i, x := range xs { r[i] = " +
               conv("x", d.elem[0], to_host) + " }; return r }(" + e + ")";
      }
      case TypeDesc::Opt: {
        if (d.elem[0].kind == TypeDesc::Class) return conv(e, d.elem[0], to_host);
        std::string from = gotype(d, !to_host), to = gotype(d, to_host);
        return "func(p " + from + ") " + to + " { if p == nil { return nil }; v := " + conv("*p", d.elem[0], to_host) +
               "; return &v }(" + e + ")";
      }
      default: break;
    }
    return e;
  }

  std::string desc_str(const TypeDesc& d) {
    switch (d.kind) {
      case TypeDesc::Void: return "v";
      case TypeDesc::Bool: return "b";
      case TypeDesc::Int: return "i";
      case TypeDesc::UInt: return "u";
      case TypeDesc::Float: return "f";
      case TypeDesc::Str: return "s";
      case TypeDesc::Any: return "a";
      case TypeDesc::Class: return "o" + std::to_string(class_id(d.key)) + ";";
      case TypeDesc::Vec: return "[" + desc_str(d.elem[0]);
      case TypeDesc::Opt: return "?" + desc_str(d.elem[0]);
    }
    return "v";
  }

  // A class that was never registered cannot be a Go type: the parameter or result is an any, and a call that really brings
  // such an object across fails with the usual "not registered" error.
  void normalize(TypeDesc& d) {
    if (d.kind == TypeDesc::Class && !find_class(impl, d.key)) {
      d.kind = TypeDesc::Any;
      d.key = nullptr;
    }
    for (TypeDesc& e : d.elem) normalize(e);
  }
  void normalize(Sig& s) {
    for (TypeDesc& p : s.params) normalize(p);
    normalize(s.result);
  }

  unsigned callable_id(Callable* c, Gen& g, Sig& sig) {
    if (!c->signature(sig))
      throw Error("nfcpoly: go: a bound callable without type information (it was not made through nfcpoly's templates)");
    normalize(sig);
    auto it = callable_ids.find(c);
    if (it != callable_ids.end()) return it->second;
    std::string s = "(";
    for (const TypeDesc& p : sig.params) s += desc_str(p);
    s += ")" + desc_str(sig.result);
    callables.push_back(c);
    unsigned id = static_cast<unsigned>(callables.size());
    callable_ids[c] = id;
    g.sigs.push_back(std::make_pair(id, s));
    return id;
  }

  // "func NAME(a0 T0, ...) R { ... }" or a method; SKIP leading parameters of SIG belong to the receiver.
  std::string func_source(const std::string& head, Callable* c, Gen& g, std::size_t skip, const char* recv_arg) {
    Sig sig;
    unsigned id = callable_id(c, g, sig);
    std::string params, args = recv_arg ? recv_arg : "";
    // Optional trailing arguments (Callable::min_arity) are Go's variadic `o ...any`: the generated code pads them with nil,
    // as the other languages' trampolines do, so the host always gets all of them.
    const std::size_t nopt = static_cast<std::size_t>(c->arity() - c->min_arity());
    const std::size_t first_opt = sig.params.size() - nopt;
    std::string pre;
    for (std::size_t k = skip; k < sig.params.size(); ++k) {
      if (k >= first_opt) {
        if (sig.params[k].kind != TypeDesc::Any)
          throw Error("nfcpoly: go: an optional argument must be a Value (any); parameter " + std::to_string(k - skip) + " is not");
        args += ", a[" + std::to_string(k - first_opt) + "]";
        continue;
      }
      std::string a = "a" + std::to_string(k - skip);
      params += (params.empty() ? "" : ", ") + a + " " + gotype(sig.params[k], false);
      args += ", " + conv(a, sig.params[k], true);
    }
    if (nopt) {
      params += (params.empty() ? "" : ", ") + std::string("o ...any");
      pre = "if len(o) > " + std::to_string(nopt) + " { panic(&nfc.Error{Class: \"ArgumentError\", Msg: \"wrong number of arguments\"}) }; a := make([]any, " +
            std::to_string(nopt) + "); copy(a, o); ";
    }
    if (!recv_arg && !args.empty()) args = args.substr(2);
    std::string call = "nfc.Call(" + std::to_string(id) + (args.empty() ? "" : ", ") + args + ")";
    const TypeDesc& r = sig.result;
    std::string out = head + "(" + params + ")";
    if (r.kind == TypeDesc::Void) return out + " { " + pre + call + " }\n";
    std::string rt = gotype(r, false);
    std::string val = r.kind == TypeDesc::Any ? call : conv(call + ".(" + gotype(r, true) + ")", r, false);
    return out + " " + rt + " { " + pre + "return " + val + " }\n";
  }

  std::string literal(const Var& v, std::string& type) {
    switch (v.kind()) {
      case Var::Nil: type = "any"; return "nil";
      case Var::Bool: type = "bool"; return v.b() ? "true" : "false";
      case Var::Int: type = "int"; return std::to_string(v.i());
      case Var::Float: type = "float64"; return float_literal(v.d());
      case Var::Str: type = "string"; return quote(v.s());
      case Var::Arr: {
        std::vector<std::string> ex, ts;
        for (const Var& e : v.a()) {
          std::string t;
          ex.push_back(literal(e, t));
          ts.push_back(t);
        }
        std::string et = ts.empty() ? "any" : ts[0];
        for (const std::string& t : ts) {
          if (t == et) continue;
          if ((t == "int" || t == "float64") && (et == "int" || et == "float64")) et = "float64";
          else et = "any";
        }
        if (et == "any")
          for (std::size_t k = 0; k < ex.size(); ++k)
            if (ts[k] != "any") ex[k] = "any(" + ex[k] + ")";
        std::string body;
        for (std::size_t k = 0; k < ex.size(); ++k) body += (k ? ", " : "") + ex[k];
        type = "[]" + et;
        return type + "{" + body + "}";
      }
      case Var::Obj: {
        auto it = class_ids.find(v.ci());
        if (it == class_ids.end()) throw Unresolved();
        unsigned long long id = ++next_obj;
        objs.emplace(id, v);
        type = "*" + v.ci()->name;
        return "_nfc_w_" + v.ci()->name + "(nfc.Ref(" + std::to_string(id) + ", " + std::to_string(it->second) + "))";
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang || h->lang != this) throw ConversionError("nfcpoly: a script value of another language cannot be declared in go");
        std::string t = type_of_handle(static_cast<GHandle*>(h)->id);
        type = t;
        return "nfc.Handle(" + std::to_string(static_cast<GHandle*>(h)->id) + ").(" + t + ")";
      }
    }
    type = "any";
    return "nil";
  }

  std::string type_of_handle(unsigned long long id) {
    Enter e(this);
    Wr w;
    w.u8(tHandle);
    w.u64(id);
    Reply r = go(opType, w.b);
    Rd rd = read_meta(r);
    std::string t = r.status == stOK ? rd.str() : "any";
    for (char c : t)
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '*' || c == '[' ||
            c == ']' || c == '(' || c == ')' || c == ',' || c == ' ' || c == '.' || c == '{' || c == '}'))
        return "any";
    if (t.find("interp.") != std::string::npos || t.find("reflect.") != std::string::npos) return "any";
    return t;
  }

  static char live_kind(const TypeDesc& d) {
    switch (d.kind) {
      case TypeDesc::Bool: return 'b';
      case TypeDesc::Int: return 'i';
      case TypeDesc::UInt: return 'u';
      case TypeDesc::Float: return 'f';
      default: return 's';
    }
  }

  // The Go source of one declaration, appended to G; Unresolved when it needs a class that is not defined yet.
  void generate(const Item& it, Gen& g) {
    switch (it.kind) {
      case Item::Fn: {
        if (!go_ident(it.name)) throw Error("nfcpoly: '" + it.name + "' is not a usable Go identifier");
        g.src += func_source("func " + it.name, it.c, g, 0, nullptr);
        break;
      }
      case Item::Val: {
        std::string t, e = literal(it.v, t);
        g.src += "var " + it.name + " " + (t == "any" && e == "nil" ? "any" : t) + " = " + e + "\n";
        break;
      }
      case Item::Variable: {
        Sig sig;
        if (!it.c->signature(sig)) throw Error("nfcpoly: go: a bound variable without type information");
        g.src += "var " + it.name + " " + gotype(sig.result, false) + "\n";
        g.lives.push_back(Live{it.name, it.c, it.c2, live_kind(sig.result)});
        break;
      }
      case Item::Class: {
        classes.push_back(it.ci);
        unsigned id = static_cast<unsigned>(classes.size());
        class_ids[it.ci] = id;
        const std::string& n = it.ci->name;
        g.src += "type " + n + " struct{ H *nfc.Obj }\n";
        g.src += "func _nfc_w_" + n + "(h *nfc.Obj) *" + n + " { if h == nil { return nil }; return &" + n + "{h} }\n";
        g.src += "func _nfc_h_" + n + "(v *" + n + ") *nfc.Obj { if v == nil { return nil }; return v.H }\n";
        g.wraps.push_back(std::make_pair(id, "_nfc_w_" + n));
        if (!it.c) {  // no constructor in this batch: NewName raises like the other languages' Name.new does
          g.src += "func New" + n + "(args ...any) *" + n + " { panic(&nfc.Error{Class: \"TypeError\", Msg: \"" + n +
                   " has no constructor (ClassBuilder::ctor)\"}) }\n";
        }
        break;
      }
      case Item::Method: {
        if (it.name.size() > 4 && it.name.compare(0, 2, "__") == 0) break;  // an operator method (Python's names): Go has none
        std::string gn = go_name(it.name);
        if (!go_ident(gn) || gn == "H") throw Error("nfcpoly: go: '" + it.name + "' is not usable as a method of " + it.ci->name);
        class_id(it.ci->key);
        g.src += func_source("func (v *" + it.ci->name + ") " + gn, it.c, g, 1, "v.H");
        break;
      }
      case Item::Prop: {
        std::string gn = go_name(it.name);
        if (!go_ident(gn) || gn == "H") throw Error("nfcpoly: go: '" + it.name + "' is not usable as a field of " + it.ci->name);
        class_id(it.ci->key);
        g.src += func_source("func (v *" + it.ci->name + ") " + gn, it.c, g, 1, "v.H");
        if (it.c2) g.src += func_source("func (v *" + it.ci->name + ") Set" + gn, it.c2, g, 1, "v.H");
        break;
      }
      case Item::Ctor: {
        class_id(it.ci->key);
        g.src += func_source("func New" + it.ci->name, it.c, g, 0, nullptr);
        break;
      }
    }
  }

  void flush() {
    Gen g;
    std::vector<Item> waiting;
    std::vector<Item> work;
    work.swap(pending);
    for (Item& ct : work)  // a class whose constructor comes in the same batch gets no stub
      if (ct.kind == Item::Ctor)
        for (Item& cl : work)
          if (cl.kind == Item::Class && cl.ci == ct.ci) cl.c = ct.c;
    // classes first
    for (int pass = 0; pass < 2; ++pass) {
      for (Item& it : work) {
        if ((it.kind == Item::Class) != (pass == 0)) continue;
        std::size_t nclasses = classes.size();
        std::size_t nsigs = g.sigs.size();
        std::size_t nlives = g.lives.size();
        std::size_t nwraps = g.wraps.size();
        std::size_t srclen = g.src.size();
        try {
          generate(it, g);
        } catch (const Unresolved&) {
          // roll back what the declaration added, and keep it for later
          if (it.kind == Item::Class) {
            for (std::size_t k = nclasses; k < classes.size(); ++k) class_ids.erase(classes[k]);
            classes.resize(nclasses);
          }
          for (std::size_t k = nsigs; k < g.sigs.size(); ++k) {
            callable_ids.erase(callables[g.sigs[k].first - 1]);
          }
          if (g.sigs.size() > nsigs) callables.resize(callables.size() - (g.sigs.size() - nsigs));
          g.sigs.resize(nsigs);
          g.lives.resize(nlives);
          g.wraps.resize(nwraps);
          g.src.resize(srclen);
          waiting.push_back(it);
        }
      }
    }
    pending.swap(waiting);
    if (g.src.empty() && g.sigs.empty() && g.lives.empty()) return;
    Enter e(this);
    Wr w;
    put_meta(w);
    w.u32(static_cast<unsigned>(g.sigs.size()));
    for (auto& s : g.sigs) {
      w.u32(s.first);
      w.str(s.second);
    }
    w.u32(static_cast<unsigned>(g.lives.size()));
    for (const Live& lv : g.lives) {
      w.str(lv.name);
      w.u8(static_cast<unsigned char>(lv.kind));
    }
    w.u32(static_cast<unsigned>(g.wraps.size()));
    for (auto& s : g.wraps) {
      w.u32(s.first);
      w.str(s.second);
    }
    w.str(g.src);
    for (const Live& lv : g.lives) lives.push_back(lv);
    Reply r = go(opDecl, w.b);
    Rd rd = read_meta(r);
    if (r.status != stOK) {
      std::string msg = r.status == stSyntax || r.status == stInternal ? rd.str() : rd.str() + ": " + rd.str();
      throw Error("nfcpoly: go: the declarations could not be defined: " + msg + "\n--- generated source ---\n" + g.src);
    }
  }

  void queue_drop(unsigned long long id) { drop_handles.push_back(id); }
};

GHandle::~GHandle() {
  if (lang) static_cast<GoLang*>(lang)->queue_drop(id);
}

// ---- the callback from Go ------------------------------------------------------------------------------------------------
// Everything the bound code throws is caught here and returned as a status: nothing may unwind into the Go frames above.
int host_dispatch(GoLang* L, const char* in, std::size_t n, char** out, std::size_t* outn) {
  int status = hostOK;
  Wr payload;
  try {
    Rd rd(in, n);
    unsigned nw = rd.u32();  // variables the script wrote since the last crossing
    for (unsigned k = 0; k < nw && !rd.bad; ++k) {
      unsigned idx = rd.u32();
      Var v = L->decode(rd);
      if (idx >= L->lives.size()) continue;
      Live& lv = L->lives[idx];
      if (!lv.set) throw ReadOnlyWrite{lv.name};
      lv.set->invoke(nullptr, &v);
    }
    unsigned nr = rd.u32();  // objects whose wrappers died
    for (unsigned k = 0; k < nr && !rd.bad; ++k) L->release(rd.u64());
    unsigned id = rd.u32();
    if (rd.bad || id == 0 || id > L->callables.size()) throw Error("nfcpoly: go: a call of an unknown host function");
    Callable* c = L->callables[id - 1];
    std::size_t total = static_cast<std::size_t>(c->arity()) + (c->wants_self() ? 1 : 0);
    std::vector<Var> args;
    for (std::size_t k = 0; k < total; ++k) args.push_back(L->decode(rd));
    if (rd.bad) throw Error("nfcpoly: go: malformed call");
    Var selfv;
    const Var* sp = nullptr;
    const Var* ap = args.data();
    if (c->wants_self()) {
      selfv = args[0];
      sp = &selfv;
      ap = args.data() + 1;
    }
    Var r = c->invoke(sp, ap);
    L->encode(payload, r);
  } catch (const ReadOnlyWrite& e) {
    status = hostPlain;
    payload = Wr();
    payload.str("ReadOnlyError");
    payload.str("variable " + e.name + " is read-only");
  } catch (const ScriptError& e) {
    payload = Wr();
    if (e.owner() == L && e.serial() == L->exc_serial) {
      status = hostRepanic;  // the script error this came from: raise that very value again
    } else {
      status = hostPlain;
      payload.str("RuntimeError");
      payload.str(e.what());
    }
  } catch (const ConversionError& e) {
    status = hostType;
    payload = Wr();
    payload.str(e.what());
  } catch (const std::exception& e) {
    status = hostException;
    payload = Wr();
    unsigned long long id = ++L->next_exc;
    L->excs[id] = std::current_exception();
    payload.u64(id | kExcBit);
    payload.str(e.what());
  } catch (...) {
    status = hostException;
    payload = Wr();
    unsigned long long id = ++L->next_exc;
    L->excs[id] = std::current_exception();
    payload.u64(id | kExcBit);
    payload.str("unknown C++ exception");
  }
  // the reply: the live variables' values, then the payload
  Wr reply;
  try {
    L->put_live(reply);
  } catch (...) {
    reply = Wr();
    reply.u32(0);
  }
  reply.b.append(payload.b);
  char* mem = static_cast<char*>(std::malloc(reply.b.size() + 1));
  if (!mem) return hostPlain;
  std::memcpy(mem, reply.b.data(), reply.b.size());
  *out = mem;
  *outn = reply.b.size();
  return status;
}

int host_cb(long long gid, int op, const char* in, std::size_t n, char** out, std::size_t* outn) {
  *out = nullptr;
  *outn = 0;
  std::shared_ptr<Slot> slot;
  GoLang* lang = nullptr;
  {
    std::lock_guard<std::mutex> g(g_mu);
    auto it = g_slots().find(gid);
    if (it != g_slots().end()) {
      slot = it->second;
      lang = slot->lang;
    }
  }
  // Only the thread that is inside a call into the interpreter may run host code. A goroutine of the script is on another
  // thread: refuse it before any host state is touched (the exception machinery of the host is not thread safe either).
  if (!lang || slot->owner.load() != static_cast<unsigned long>(pthread_self()) || op != 1) return hostThread;
  try {
    return host_dispatch(lang, in, n, out, outn);
  } catch (...) {
    return hostPlain;  // not reached; nothing may unwind into Go
  }
}

std::unique_ptr<Lang> make_go(Impl* impl) { return std::unique_ptr<Lang>(new GoLang(impl)); }
LangRegistrar registrar("go", "golang", nullptr, &make_go);

}  // namespace
}  // namespace detail

void go_collect(Context& ctx) { ctx.eval_void("go", "nfc.GC()"); }

}  // namespace nfcpoly
