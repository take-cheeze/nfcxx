// nfcpoly JavaScript backend: QuickJS-NG, embedded (scripts/setup-poly-js.sh). See docs/notes/poly.md.
//
// QuickJS reports errors through return values (JS_EXCEPTION and JS_GetException), never by unwinding, so a C++ exception
// must not cross a QuickJS frame and none does: the trampolines catch what bound code throws and throw a JavaScript
// exception instead. A host exception that enters a script travels in an NfcPoly::HostError object, in a property that
// only C code can name (a private symbol) holding a std::exception_ptr.
//
// Numbers: JavaScript has one number type. A number is an integer for the host when it is a whole value within the safe
// integer range (|n| <= 2^53 - 1, and not -0); BigInts that fit 64 bits are integers too. The other direction: an integer
// that is not a safe integer becomes a BigInt, so a C++ long long survives the round trip.
//
// One QuickJS runtime and context per Context. Every JSValue the backend keeps (handles, prototypes, the last error) is
// freed before the runtime closes: QuickJS asserts that no object is left.
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>

#include "nfcpoly_js.hpp"
#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

struct JsLang;

// An owned JSValue, freed on every path.
struct Val {
  JSContext* c;
  JSValue v;
  Val(JSContext* ctx, JSValue x) : c(ctx), v(x) {}
  Val(const Val&) = delete;
  Val& operator=(const Val&) = delete;
  ~Val() { JS_FreeValue(c, v); }
  JSValue get() const { return v; }
  JSValue dup() const { return JS_DupValue(c, v); }
  JSValue release() {
    JSValue r = v;
    v = JS_UNDEFINED;
    return r;
  }
};

struct JsObj {  // the opaque data of a bound class instance
  ClassInfo* ci;
  void* p;
  Owned* own;
};

struct JHandle : Handle {
  JSContext* ctx;
  JSValue v;
  JHandle(Lang* l, Impl* i, JSContext* c, JSValue val) : Handle(l, i), ctx(c), v(val) {}  // adopts the reference
  ~JHandle() override {
    if (lang && ctx) JS_FreeValue(ctx, v);
  }
  void orphan() override;
};

struct Bound {  // what a bound function, method or accessor needs when JavaScript calls it
  JsLang* lang;
  Callable* c;
  ClassInfo* ci;     // a constructor: the class
  std::string name;  // the variable of a read-only setter
};

struct JsClass {
  JSValue ctor;
  JSValue proto;
};

struct Pending {  // what a trampoline raises once the C++ handlers have finished
  enum Kind { None, Existing, TypeErr, Plain, Host } kind = None;
  std::string msg;
  std::exception_ptr host;
};

bool valid_utf8(const std::string& s) {
  std::size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    std::size_t len;
    unsigned long cp;
    if (c < 0x80) {
      ++i;
      continue;
    } else if (c >= 0xc2 && c <= 0xdf) {
      len = 2;
      cp = c & 0x1f;
    } else if (c >= 0xe0 && c <= 0xef) {
      len = 3;
      cp = c & 0x0f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      len = 4;
      cp = c & 0x07;
    } else {
      return false;
    }
    if (i + len > n) return false;
    for (std::size_t k = 1; k < len; ++k) {
      unsigned char d = static_cast<unsigned char>(s[i + k]);
      if ((d & 0xc0) != 0x80) return false;
      cp = (cp << 6) | (d & 0x3f);
    }
    if ((len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000) || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
      return false;
    i += len;
  }
  return true;
}

// Text for a message: invalid bytes become '?', so that a bytes-like exception message cannot make the error itself fail.
std::string sanitized(const std::string& s) {
  if (valid_utf8(s)) return s;
  std::string out;
  for (char c : s) out += (static_cast<unsigned char>(c) < 0x80 ? c : '?');
  return out;
}

JSValue fn_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int magic, void* opaque);
JSValue method_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int magic, void* opaque);
JSValue ctor_tramp(JSContext* ctx, JSValueConst new_target, int argc, JSValueConst* argv, int magic, void* opaque);
JSValue readonly_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int magic, void* opaque);
JSValue tostring_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int magic, void* opaque);
void obj_finalizer(JSRuntime* rt, JSValueConst val);
void host_finalizer(JSRuntime* rt, JSValueConst val);

const char* const kBootstrap =
    "(function () {\n"
    "  class HostError extends Error {}\n"
    "  Object.defineProperty(HostError.prototype, 'name', {value: 'NfcPoly::HostError', writable: true, configurable: true});\n"
    "  Object.defineProperty(HostError, 'name', {value: 'NfcPoly::HostError', configurable: true});\n"
    "  return HostError;\n"
    "})()";

// ---- the language --------------------------------------------------------------------------------------------------
struct JsLang : Lang {
  JSRuntime* rt = nullptr;
  JSContext* ctx = nullptr;
  JSClassID obj_class = 0;   // bound class instances
  JSClassID host_class = 0;  // the holder of a std::exception_ptr
  JSAtom host_atom = 0;      // private symbol: the property of an NfcPoly::HostError that holds the holder
  JSValue host_error = JS_UNDEFINED;  // the NfcPoly::HostError class
  JSValue last_exc = JS_UNDEFINED;    // the script error last handed to the host (strong)
  std::vector<JSValue> graveyard;     // values of orphaned handles, freed when the runtime closes
  std::map<ClassInfo*, JsClass> classes;
  std::vector<std::unique_ptr<Bound>> bounds;
  int depth = 0;  // nesting of calls from the host into the interpreter

  explicit JsLang(Impl* i) : Lang(i) {
    try {
      rt = JS_NewRuntime();
      if (!rt) throw Error("nfcpoly: JS_NewRuntime failed (out of memory)");
      JS_SetCanBlock(rt, false);  // Atomics.wait would hang the host thread
      ctx = JS_NewContext(rt);
      if (!ctx) throw Error("nfcpoly: JS_NewContext failed (out of memory)");
      JS_NewClassID(rt, &obj_class);
      JSClassDef od;
      std::memset(&od, 0, sizeof od);
      od.class_name = "NfcPolyObject";
      od.finalizer = obj_finalizer;
      if (JS_NewClass(rt, obj_class, &od) < 0) throw Error("nfcpoly: JS_NewClass failed");
      JS_NewClassID(rt, &host_class);
      JSClassDef hd;
      std::memset(&hd, 0, sizeof hd);
      hd.class_name = "NfcPolyHostException";
      hd.finalizer = host_finalizer;
      if (JS_NewClass(rt, host_class, &hd) < 0) throw Error("nfcpoly: JS_NewClass failed");
      Val sym(ctx, JS_NewPrivateSymbol(ctx, "nfcpoly.host"));
      host_atom = JS_ValueToAtom(ctx, sym.get());
      host_error = JS_Eval(ctx, kBootstrap, std::strlen(kBootstrap), "nfcpoly-bootstrap", JS_EVAL_TYPE_GLOBAL);
      if (JS_IsException(host_error)) {
        host_error = JS_UNDEFINED;
        throw Error("nfcpoly: the JavaScript bootstrap failed");
      }
    } catch (...) {
      close();
      throw;
    }
  }
  ~JsLang() override { close(); }
  const char* name() const override { return "js"; }

  void close() {
    if (ctx) {
      JS_FreeValue(ctx, host_error);
      JS_FreeValue(ctx, last_exc);
      host_error = last_exc = JS_UNDEFINED;
      for (auto& kv : classes) {
        JS_FreeValue(ctx, kv.second.ctor);
        JS_FreeValue(ctx, kv.second.proto);
      }
      classes.clear();
      // The values of orphaned handles: freeing them can finalize script-owned C++ objects, whose destructors may drop
      // Values; those handles are all orphaned by now.
      for (JSValue g : graveyard) JS_FreeValue(ctx, g);
      graveyard.clear();
      if (host_atom) JS_FreeAtom(ctx, host_atom);
      host_atom = 0;
      JS_FreeContext(ctx);
      ctx = nullptr;
    }
    if (rt) {
      JS_FreeRuntime(rt);  // runs the finalizers of what remains (script-owned C++ objects)
      rt = nullptr;
    }
  }

  // ---- calls from the host into the interpreter ----
  struct Entry {  // the outermost entry re-measures the native stack (the host may call from any depth)
    JsLang* l;
    explicit Entry(JsLang* x) : l(x) {
      if (l->depth++ == 0) JS_UpdateStackTop(l->rt);
    }
    ~Entry() { --l->depth; }
  };

  void clear_exception() { JS_FreeValue(ctx, JS_GetException(ctx)); }

  std::string text_of(JSValueConst v) {  // UTF-8 of a string value; an error in the conversion becomes a ScriptError
    std::size_t n = 0;
    const char* s = JS_ToCStringLen(ctx, &n, v);
    if (!s) throw_error(false);
    std::string out(s, n);
    JS_FreeCString(ctx, s);
    return out;
  }

  // ---- values ----
  Var handle_of(JSValueConst v) { return Var::script(new JHandle(this, impl, ctx, JS_DupValue(ctx, v))); }

  static Var number_var(double d) {
    if (d == std::floor(d) && std::fabs(d) <= 9007199254740991.0 && !(d == 0 && 1.0 / d < 0))
      return Var::integer(static_cast<long long>(d));
    return Var::real(d);
  }

  Var decode(JSValueConst v) {  // shallow
    Var r;
    if (JS_IsUndefined(v) || JS_IsNull(v)) {
    } else if (JS_IsBool(v)) {
      r = Var::boolean(JS_VALUE_GET_BOOL(v) != 0);
    } else if (JS_VALUE_GET_TAG(v) == JS_TAG_INT) {
      r = Var::integer(JS_VALUE_GET_INT(v));
    } else if (JS_IsNumber(v)) {
      r = number_var(JS_VALUE_GET_FLOAT64(v));
    } else if (JS_IsBigInt(v)) {
      int64_t i = 0;
      bool fits = false;
      if (JS_ToBigInt64(ctx, &i, v) == 0) {
        Val back(ctx, JS_NewBigInt64(ctx, i));
        fits = JS_IsStrictEqual(ctx, back.get(), v);
      } else {
        clear_exception();
      }
      if (fits) r = Var::integer(i);
      else r = handle_of(v);
    } else if (JS_IsString(v)) {
      std::string text = text_of(v);
      // A string with a lone surrogate has no UTF-8 form (QuickJS writes it as the invalid bytes ED A0..BF xx): it stays in
      // JavaScript.
      if (valid_utf8(text)) r = Var::string(std::move(text));
      else r = handle_of(v);
    } else if (JS_IsObject(v)) {
      JsObj* o = JS_GetClassID(v) == obj_class ? static_cast<JsObj*>(JS_GetOpaque(v, obj_class)) : nullptr;
      if (o) r = Var::object(o->ci, o->p, o->own);
      else r = handle_of(v);
    } else {
      r = handle_of(v);  // symbols
    }
    r.set_src(this);
    return r;
  }

  JSValue new_object_for(const JsClass& jc, JSValueConst proto, ClassInfo* ci, void* p, Owned* own) {
    JSValue o;
    if (JS_IsObject(proto)) o = JS_NewObjectProtoClass(ctx, proto, obj_class);
    else o = JS_NewObjectProtoClass(ctx, jc.proto, obj_class);
    if (JS_IsException(o)) throw_error(false);
    JsObj* jo = new JsObj{ci, p, own};
    if (own) owned_ref(own);
    JS_SetOpaque(o, jo);
    return o;
  }

  // A new reference. On failure a C++ exception.
  JSValue encode(const Var& v) {
    switch (v.kind()) {
      case Var::Nil: return JS_NULL;
      case Var::Bool: return JS_NewBool(ctx, v.b());
      case Var::Int: {
        long long i = v.i();
        if (i >= -9007199254740991LL && i <= 9007199254740991LL) return JS_NewNumber(ctx, static_cast<double>(i));
        return check(JS_NewBigInt64(ctx, static_cast<int64_t>(i)));
      }
      case Var::Float: return JS_NewFloat64(ctx, v.d());
      case Var::Str: {
        if (valid_utf8(v.s())) return check(JS_NewStringLen(ctx, v.s().data(), v.s().size()));
        // not text: a Uint8Array of the bytes
        return check(JS_NewUint8ArrayCopy(ctx, reinterpret_cast<const uint8_t*>(v.s().data()), v.s().size()));
      }
      case Var::Arr: {
        Val arr(ctx, check(JS_NewArray(ctx)));
        uint32_t k = 0;
        for (const Var& e : v.a()) {
          JSValue x = encode(e);
          if (JS_SetPropertyUint32(ctx, arr.get(), k++, x) < 0) throw_error(false);
        }
        return arr.release();
      }
      case Var::Obj: {
        auto it = classes.find(v.ci());
        if (it == classes.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in js");
        return new_object_for(it->second, JS_UNDEFINED, v.ci(), v.ptr(), v.owned());
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) return JS_DupValue(ctx, static_cast<JHandle*>(h)->v);
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to js");
        return encode(d);
      }
    }
    return JS_NULL;
  }

  JSValue check(JSValue v) {  // a failed allocation becomes a C++ exception
    if (JS_IsException(v)) throw_error(false);
    return v;
  }

  // ---- errors ----
  // The host exception a HostError object carries, if exc is one (null otherwise).
  std::exception_ptr host_of(JSValueConst exc) {
    if (!JS_IsObject(exc)) return std::exception_ptr();
    JSValue h = JS_GetProperty(ctx, exc, host_atom);
    std::exception_ptr ep;
    if (JS_IsObject(h)) {
      if (void* p = JS_GetOpaque(h, host_class)) ep = *static_cast<std::exception_ptr*>(p);
    } else if (JS_IsException(h)) {
      clear_exception();
    }
    JS_FreeValue(ctx, h);
    return ep;
  }

  std::string string_prop(JSValueConst obj, const char* prop, bool* found) {
    Val p(ctx, JS_GetPropertyStr(ctx, obj, prop));
    if (JS_IsException(p.get())) {
      clear_exception();
      *found = false;
      return std::string();
    }
    *found = JS_IsString(p.get());
    if (!*found) return std::string();
    const char* s = JS_ToCString(ctx, p.get());
    if (!s) {
      clear_exception();
      *found = false;
      return std::string();
    }
    std::string out(s);
    JS_FreeCString(ctx, s);
    return out;
  }

  // The pending JavaScript exception becomes the host's exception: the original C++ exception when the script carried one
  // out unrescued, else ScriptError (SyntaxError when `syntax`: the source did not parse). Never returns.
  [[noreturn]] void throw_error(bool syntax) {
    Val exc(ctx, JS_GetException(ctx));
    if (std::exception_ptr ep = host_of(exc.get())) std::rethrow_exception(ep);
    std::string cls = "Error", msg;
    std::vector<std::string> bt;
    if (JS_IsObject(exc.get())) {
      // An Error, or any object that looks like one: its name (an object without one is a plain "Error").
      bool found = false;
      std::string name = string_prop(exc.get(), "name", &found);
      if (found && !name.empty()) cls = name;
      if (JS_IsError(exc.get()) && (!found || name == "Error")) {  // a subclass of Error that keeps the name: the constructor says more
        Val ctor(ctx, JS_GetPropertyStr(ctx, exc.get(), "constructor"));
        if (JS_IsObject(ctor.get())) {
          std::string cn = string_prop(ctor.get(), "name", &found);
          if (found && !cn.empty()) cls = cn;
        } else if (JS_IsException(ctor.get())) {
          clear_exception();
        }
      }
      msg = string_prop(exc.get(), "message", &found);
      if (!found) msg = to_text(exc.get());
      std::string stack = string_prop(exc.get(), "stack", &found);
      std::size_t pos = 0;
      while (found && pos < stack.size()) {
        std::size_t e = stack.find('\n', pos);
        if (e == std::string::npos) e = stack.size();
        std::string line = stack.substr(pos, e - pos);
        std::size_t b = line.find_first_not_of(" \t");
        if (b != std::string::npos) bt.push_back(line.substr(b));
        pos = e + 1;
      }
    } else {
      msg = to_text(exc.get());  // a thrown string, number, null ...
    }
    if (!syntax) {
      JS_FreeValue(ctx, last_exc);
      last_exc = exc.dup();  // so that a trampoline can raise this very value again
    }
    raise_script_error(this, cls, msg, std::move(bt), syntax);
  }

  std::string to_text(JSValueConst v) {  // String(v), or a placeholder when that throws (a hostile toString)
    JSValue s;
    if (JS_IsSymbol(v)) {  // the conversion refuses a Symbol; String(symbol) is its toString()
      Val f(ctx, JS_GetPropertyStr(ctx, v, "toString"));
      if (JS_IsException(f.get())) s = JS_EXCEPTION;
      else s = JS_Call(ctx, f.get(), v, 0, nullptr);
    } else {
      s = JS_ToString(ctx, v);
    }
    if (JS_IsException(s)) {
      clear_exception();
      return "[uncaught value]";
    }
    const char* c = JS_ToCString(ctx, s);
    std::string out = c ? c : "";
    if (c) JS_FreeCString(ctx, c);
    else clear_exception();
    JS_FreeValue(ctx, s);
    return out;
  }

  // Runs the jobs that promises queued (microtasks), as an engine does when its stack empties. A job that throws is an
  // error of the host call that ran it (the first one, once every job has run).
  void run_jobs() {
    std::exception_ptr first;
    for (;;) {
      JSContext* jc = nullptr;
      int r = JS_ExecutePendingJob(rt, &jc);
      if (r == 0) break;
      if (r < 0) {
        try {
          throw_error(false);
        } catch (...) {
          if (!first) first = std::current_exception();
        }
      }
    }
    if (first) std::rethrow_exception(first);
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    Entry entry(this);
    std::string src(code);  // QuickJS wants a terminating NUL
    Val fn(ctx, JS_Eval(ctx, src.c_str(), src.size(), "snippet", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY));
    if (JS_IsException(fn.get())) throw_error(true);
    Val r(ctx, JS_EvalFunction(ctx, fn.release()));
    if (JS_IsException(r.get())) throw_error(false);
    if (depth == 1) run_jobs();
    return decode(r.get());
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth_) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    JSValue jv = static_cast<JHandle*>(v.handle())->v;
    if (!JS_IsArray(jv)) return v;
    if (depth_ > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    int64_t n = 0;
    if (JS_GetLength(ctx, jv, &n) < 0) throw_error(false);
    if (n > (1 << 24)) throw ConversionError("nfcpoly: array too long to convert");
    std::vector<Var> out;
    out.reserve(static_cast<std::size_t>(n));
    for (int64_t k = 0; k < n; ++k) {
      Val e(ctx, JS_GetPropertyInt64(ctx, jv, k));
      if (JS_IsException(e.get())) throw_error(false);
      out.push_back(deep_var(decode(e.get()), depth_ + 1));
    }
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    Entry entry(this);
    Val self(ctx, encode(target));
    Val fn(ctx, JS_UNDEFINED);
    if (method.empty()) {  // the value itself is the function
      fn.v = self.dup();
    } else {
      fn.v = JS_GetPropertyStr(ctx, self.get(), method.c_str());
      if (JS_IsException(fn.get())) throw_error(false);
    }
    std::vector<JSValue> av;
    struct Free {  // the arguments, on every path
      JsLang* l;
      std::vector<JSValue>& v;
      ~Free() {
        for (JSValue x : v) JS_FreeValue(l->ctx, x);
      }
    } freeing{this, av};
    av.reserve(args.size());
    for (const Var& a : args) av.push_back(encode(a));
    JSValue this_v = JS_UNDEFINED;
    if (!method.empty()) this_v = self.get();
    Val r(ctx, JS_Call(ctx, fn.get(), this_v, static_cast<int>(av.size()), av.data()));
    if (JS_IsException(r.get())) throw_error(false);
    if (depth == 1) run_jobs();
    return decode(r.get());
  }

  std::string inspect(const Var& v) override {
    Val o(ctx, encode(v));
    if (v.kind() != Var::Obj && !JS_IsBigInt(o.get())) {
      JSValue s = JS_JSONStringify(ctx, o.get(), JS_UNDEFINED, JS_UNDEFINED);  // quoted strings, [..] and {..}
      if (JS_IsException(s)) {
        clear_exception();
      } else {
        bool is_text = JS_IsString(s);
        std::string out;
        if (is_text) out = text_of(s);
        JS_FreeValue(ctx, s);
        if (is_text) return out;
      }
    }
    std::string t = to_text(o.get());
    if (t == "[uncaught value]") return type_name(v);
    return t;
  }

  std::string type_name(const Var& v) override {
    Val o(ctx, encode(v));
    if (JS_IsUndefined(o.get())) return "undefined";
    if (JS_IsNull(o.get())) return "null";
    if (JS_IsBool(o.get())) return "boolean";
    if (JS_IsNumber(o.get())) return "number";
    if (JS_IsBigInt(o.get())) return "bigint";
    if (JS_IsString(o.get())) return "string";
    if (JS_IsSymbol(o.get())) return "symbol";
    Val ctor(ctx, JS_GetPropertyStr(ctx, o.get(), "constructor"));
    if (JS_IsException(ctor.get())) clear_exception();
    else if (JS_IsObject(ctor.get())) {
      bool found = false;
      std::string n = string_prop(ctor.get(), "name", &found);
      if (found && !n.empty()) return n;
    }
    return "Object";
  }

  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    return JS_IsArray(static_cast<JHandle*>(v.handle())->v);
  }

  // ---- declarations ----
  Bound* new_bound(Callable* c, ClassInfo* ci = nullptr, const std::string& name = std::string()) {
    bounds.push_back(std::unique_ptr<Bound>(new Bound{this, c, ci, name}));
    return bounds.back().get();
  }
  JSValue make_fn(JSCClosure* f, const std::string& name, int length, Bound* b) {
    return check(JS_NewCClosure(ctx, f, name.c_str(), nullptr, length, 0, b));
  }
  void define_global(const std::string& name, JSValue v, int flags) {  // consumes v
    Val g(ctx, JS_GetGlobalObject(ctx));
    if (JS_DefinePropertyValueStr(ctx, g.get(), name.c_str(), v, flags) < 0) throw_error(false);
  }

  void define_fn(const std::string& name, Callable* c) override {
    define_global(name, make_fn(fn_tramp, name, c->arity(), new_bound(c)), JS_PROP_C_W_E);
  }
  void define_value(const std::string& name, const Var& v) override { define_global(name, encode(v), JS_PROP_C_W_E); }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    Val g(ctx, JS_GetGlobalObject(ctx));
    JSAtom a = JS_NewAtom(ctx, name.c_str());
    JSValue getter = make_fn(fn_tramp, name, 0, new_bound(get));
    JSValue setter;
    if (set) setter = make_fn(fn_tramp, name, 1, new_bound(set));
    else setter = make_fn(readonly_tramp, name, 1, new_bound(nullptr, nullptr, "variable " + name));
    int rc = JS_DefinePropertyGetSet(ctx, g.get(), a, getter, setter, JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE);
    JS_FreeAtom(ctx, a);
    if (rc < 0) throw_error(false);
  }
  void class_define(ClassInfo* ci) override {
    JsClass jc;
    jc.proto = check(JS_NewObject(ctx));
    jc.ctor = JS_UNDEFINED;
    try {
      jc.ctor = make_fn(ctor_tramp, ci->name, 0, new_bound(nullptr, ci));
      JS_SetConstructorBit(ctx, jc.ctor, true);
      if (JS_SetConstructor(ctx, jc.ctor, jc.proto) < 0) throw_error(false);
      JSValue ts = make_fn(tostring_tramp, "toString", 0, new_bound(nullptr, ci));
      if (JS_DefinePropertyValueStr(ctx, jc.proto, "toString", ts, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0)
        throw_error(false);
      define_global(ci->name, JS_DupValue(ctx, jc.ctor), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    } catch (...) {
      JS_FreeValue(ctx, jc.ctor);
      JS_FreeValue(ctx, jc.proto);
      throw;
    }
    classes[ci] = jc;
  }
  void class_method(ClassInfo* ci, const std::string& name, Callable* c) override {
    JSValue fn = make_fn(method_tramp, name, c->arity(), new_bound(c));
    if (JS_DefinePropertyValueStr(ctx, classes.at(ci).proto, name.c_str(), fn, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0)
      throw_error(false);
  }
  void class_prop(ClassInfo* ci, const std::string& name, Callable* get, Callable* set) override {
    JSAtom a = JS_NewAtom(ctx, name.c_str());
    JSValue getter = make_fn(method_tramp, name, 0, new_bound(get));
    JSValue setter;
    if (set) setter = make_fn(method_tramp, name, 1, new_bound(set));
    else setter = make_fn(readonly_tramp, name, 1, new_bound(nullptr, ci, "field " + name + " of " + ci->name));
    int rc = JS_DefinePropertyGetSet(ctx, classes.at(ci).proto, a, getter, setter, JS_PROP_CONFIGURABLE);
    JS_FreeAtom(ctx, a);
    if (rc < 0) throw_error(false);
  }
  void class_ctor(ClassInfo*, Callable*) override {}  // the constructor function reads ClassInfo::ctor when it is called

  // ---- what the trampolines use ----
  JSValue raise_pending(Pending& p) {
    switch (p.kind) {
      case Pending::Existing: return JS_Throw(ctx, JS_DupValue(ctx, last_exc));
      case Pending::TypeErr: return JS_ThrowTypeError(ctx, "%s", sanitized(p.msg).c_str());
      case Pending::Plain: return JS_ThrowPlainError(ctx, "%s", sanitized(p.msg).c_str());
      case Pending::Host: {
        std::string m = sanitized(p.msg);
        Val msg(ctx, JS_NewStringLen(ctx, m.data(), m.size()));
        JSValue argv[1] = {msg.get()};
        JSValue e = JS_CallConstructor(ctx, host_error, 1, argv);
        if (JS_IsException(e)) return e;
        JSValue holder = JS_NewObjectClass(ctx, host_class);
        if (JS_IsException(holder)) {
          JS_FreeValue(ctx, e);
          return holder;
        }
        JS_SetOpaque(holder, new std::exception_ptr(p.host));
        JS_DefinePropertyValue(ctx, e, host_atom, holder, 0);  // not enumerable, not writable
        return JS_Throw(ctx, e);
      }
      case Pending::None: break;
    }
    return JS_EXCEPTION;
  }
};

void JHandle::orphan() {
  // Not freed here: this runs while the context walks its list of handles, and freeing can finalize script-owned C++
  // objects whose destructors drop other handles. The JsLang frees the value when it closes.
  if (ctx) static_cast<JsLang*>(lang)->graveyard.push_back(v);
  v = JS_UNDEFINED;
  ctx = nullptr;
}

// Runs BODY, the part of a trampoline that may throw C++ exceptions; every one becomes a JavaScript exception.
template <class F>
JSValue guarded(JsLang* lang, JSContext* ctx, F body) {
  (void)ctx;
  Pending pend;
  try {
    return body();
  } catch (const ScriptError& e) {
    if (e.owner() == lang && e.serial() == lang->exc_serial) {
      pend.kind = Pending::Existing;  // the script error this came from: raise that very value again
    } else {
      pend.kind = Pending::Plain;
      pend.msg = e.what();
    }
  } catch (const ConversionError& e) {
    pend.kind = Pending::TypeErr;
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
  return lang->raise_pending(pend);
}

// Calls c with the arguments of a JavaScript call; the result as a JavaScript value (a new reference).
JSValue call_callable(JsLang* lang, Callable* c, JSValueConst this_val, int argc, JSValueConst* argv) {
  if (argc != c->arity())
    throw ConversionError("wrong number of arguments (given " + std::to_string(argc) + ", expected " +
                          std::to_string(c->arity()) + ")");
  std::vector<Var> args;
  args.reserve(static_cast<std::size_t>(argc));
  for (int k = 0; k < argc; ++k) args.push_back(lang->decode(argv[k]));
  Var selfv;
  const Var* sp = nullptr;
  if (c->wants_self()) {
    selfv = lang->decode(this_val);
    sp = &selfv;
  }
  Var r = c->invoke(sp, args.data());
  return lang->encode(r);
}

JSValue fn_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int, void* opaque) {
  Bound* b = static_cast<Bound*>(opaque);
  return guarded(b->lang, ctx, [&]() { return call_callable(b->lang, b->c, this_val, argc, argv); });
}

JSValue method_tramp(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv, int, void* opaque) {
  Bound* b = static_cast<Bound*>(opaque);
  return guarded(b->lang, ctx, [&]() { return call_callable(b->lang, b->c, this_val, argc, argv); });
}

JSValue readonly_tramp(JSContext* ctx, JSValueConst, int, JSValueConst*, int, void* opaque) {
  Bound* b = static_cast<Bound*>(opaque);
  return JS_ThrowTypeError(ctx, "%s is read-only", b->name.c_str());
}

JSValue tostring_tramp(JSContext* ctx, JSValueConst this_val, int, JSValueConst*, int, void* opaque) {
  Bound* b = static_cast<Bound*>(opaque);
  (void)this_val;
  std::string s = "<" + b->ci->name + " object>";
  return JS_NewStringLen(ctx, s.data(), s.size());
}

JSValue ctor_tramp(JSContext* ctx, JSValueConst new_target, int argc, JSValueConst* argv, int, void* opaque) {
  Bound* b = static_cast<Bound*>(opaque);
  JsLang* lang = b->lang;
  ClassInfo* ci = b->ci;
  return guarded(lang, ctx, [&]() {
    if (!JS_IsConstructor(ctx, new_target))
      throw ConversionError("Class constructor " + ci->name + " cannot be invoked without 'new'");
    if (!ci->ctor) throw ConversionError(ci->name + " has no constructor (ClassBuilder::ctor)");
    if (argc != ci->ctor->arity())
      throw ConversionError("wrong number of arguments (given " + std::to_string(argc) + ", expected " +
                            std::to_string(ci->ctor->arity()) + ")");
    std::vector<Var> args;
    args.reserve(static_cast<std::size_t>(argc));
    for (int k = 0; k < argc; ++k) args.push_back(lang->decode(argv[k]));
    Var r = ci->ctor->invoke(nullptr, args.data());  // a new object the script owns
    if (r.kind() != Var::Obj) throw ConversionError("nfcpoly: the constructor of " + ci->name + " did not make an object");
    Val proto(ctx, JS_GetPropertyStr(ctx, new_target, "prototype"));  // a subclass in JavaScript keeps its own
    if (JS_IsException(proto.get())) lang->throw_error(false);
    return lang->new_object_for(lang->classes.at(ci), proto.get(), r.ci(), r.ptr(), r.owned());
  });
}

void obj_finalizer(JSRuntime*, JSValueConst val) {
  JSClassID cid = 0;
  JsObj* o = static_cast<JsObj*>(JS_GetAnyOpaque(val, &cid));
  if (!o) return;
  if (o->own) owned_unref(o->own);
  delete o;
}

void host_finalizer(JSRuntime*, JSValueConst val) {
  JSClassID cid = 0;
  std::exception_ptr* p = static_cast<std::exception_ptr*>(JS_GetAnyOpaque(val, &cid));
  delete p;
}

std::unique_ptr<Lang> make_js(Impl* impl) { return std::unique_ptr<Lang>(new JsLang(impl)); }
LangRegistrar registrar("js", "javascript", "quickjs", &make_js);

// The JsLang the Value belongs to (it must be alive).
JsLang* lang_of_value(const Value& v) {
  const Var& var = v.var();
  Impl* impl = impl_for(var);  // throws Error when the Value is empty or its context is gone
  Lang* l = get_lang(impl, "js");
  const Lang* src = var.kind() == Var::Script ? var.handle()->lang : var.src();
  if (src != l) throw Error("nfcpoly: the Value does not come from the js language");
  return static_cast<JsLang*>(l);
}

}  // namespace
}  // namespace detail

JSContext* js_context(Context& ctx) { return static_cast<detail::JsLang*>(detail::get_lang(ctx.impl(), "js"))->ctx; }

JSValue js_value(const Value& v) {
  return detail::lang_of_value(v)->encode(v.var());
}

Value js_wrap(Context& ctx, JSValueConst v) {
  detail::JsLang* l = static_cast<detail::JsLang*>(detail::get_lang(ctx.impl(), "js"));
  return Value(l->decode(v));
}

}  // namespace nfcpoly
