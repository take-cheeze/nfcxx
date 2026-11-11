// nfcpoly "astro" backend: ASTro's luastro (sample/luastro of ko1/astro), a Lua 5.4 subset on a generated AST interpreter, built as
// a library by scripts/setup-poly-astro.sh around lib/poly/nfcpoly_astro_shim.c. See docs/notes/poly.md and docs/notes/astro.md.
//
// What luastro's value model has: nil, booleans, 63-bit integers, doubles, strings, tables, Lua functions and C functions. No
// userdata, no light userdata, no finalizers, no metatable hook on the global table. So this backend has plain values, arrays
// (tables), script handles (Value), bound functions, bound variables and errors, and no registered classes (docs/notes/poly.md).
//
// A script error is a longjmp in C (to the innermost pcall frame of the interpreter), so it never crosses a C++ frame: the shim
// runs every script inside lua_pcall and the host function trampoline (host_cb) catches whatever the Callable throws and hands
// the interpreter an error value to raise once the C++ frame is gone. The error values are the Lua backend's: a table
// {class=, message=} (error("text") raises a plain string, class "LuaError"), and a host exception that entered the script travels
// as the number of an entry of `hosts` in the field `host`.
//
// Bound variables are copied across the boundaries: into the script's globals when a script (a program or a function called from
// C++) starts or a host function returns, and back to the host (the setter) when it ends or a host function is called, since the
// global table of luastro cannot be hooked. The Go backend works the same way.
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <memory>

#include "nfcpoly_astro_shim.h"
#include "nfcpoly_lang.hpp"

namespace nfcpoly {
namespace detail {

namespace {

struct AstroLang;

struct AHandle : Handle {
  AstroLang* al;
  long id;
  AHandle(Lang* l, Impl* i, AstroLang* a, long n) : Handle(l, i), al(a), id(n) {}
  ~AHandle() override;
  void orphan() override { al = nullptr; }
};

// A failure of the copy of a bound variable, raised as a script error where the script is running and as one on the host side
// where it is not.
struct VarError {
  std::string cls, msg;
};

const long kLastErrRoot = 1;  // the root holding the script error value the backend last handed to the host

struct AstroLang : Lang {
  struct LiveVar {
    std::string name;
    Callable* get;
    Callable* set;
    Var last;  // what the global held when it was last copied
  };
  std::vector<Callable*> fns;
  std::vector<LiveVar> live;
  std::vector<long> free_ids;
  long next_id = kLastErrRoot + 1;
  std::map<long, std::exception_ptr> hosts;
  long next_host = 1;
  bool open = false;

  explicit AstroLang(Impl* i) : Lang(i) {
    if (nfc_ls_open(&AstroLang::host_cb, this) != 0)
      throw Error("nfcpoly: astro (luastro) keeps its interpreter in process globals: one Context at a time can use it");
    open = true;
  }
  ~AstroLang() override {
    if (open) nfc_ls_close();
  }
  const char* name() const override { return "astro"; }

  // ---- roots ----
  long root(nfc_lv v) {
    long id;
    if (!free_ids.empty()) {
      id = free_ids.back();
      free_ids.pop_back();
    } else {
      id = next_id++;
    }
    nfc_ls_root_set(id, v);
    return id;
  }
  void unroot(long id) {
    nfc_ls_root_set(id, 0);  // nil is the word 0
    free_ids.push_back(id);
  }

  // ---- values ----
  Var decode(nfc_lv v) {  // shallow
    Var r;
    switch (nfc_ls_kind(v)) {
      case NFC_NIL: break;
      case NFC_BOOL: r = Var::boolean(nfc_ls_as_bool(v) != 0); break;
      case NFC_INT: r = Var::integer(nfc_ls_as_int(v)); break;
      case NFC_FLOAT: r = Var::real(nfc_ls_as_float(v)); break;
      case NFC_STR: r = Var::string(std::string(nfc_ls_str_data(v), nfc_ls_str_len(v))); break;
      default: r = Var::script(new AHandle(this, impl, this, root(v))); break;  // table, function, thread
    }
    r.set_src(this);
    return r;
  }

  nfc_lv push(const Var& v) {
    switch (v.kind()) {
      case Var::Nil: return 0;
      case Var::Bool: return nfc_ls_mk_bool(v.b() ? 1 : 0);
      case Var::Int:
        if (!nfc_ls_int_fits(v.i())) throw ConversionError("nfcpoly: integer out of range for astro (luastro integers have 63 bits)");
        return nfc_ls_mk_int(v.i());
      case Var::Float: return nfc_ls_mk_float(v.d());
      case Var::Str: return nfc_ls_mk_str(v.s().data(), v.s().size());
      case Var::Arr: {
        nfc_lv t = nfc_ls_mk_table(static_cast<unsigned>(v.a().size()), 0);
        long long k = 1;
        for (const Var& e : v.a()) nfc_ls_table_seti(t, k++, push(e));
        return t;
      }
      case Var::Obj: throw ConversionError("nfcpoly: astro (luastro) has no registered classes: " + v.ci()->name + " cannot cross into it");
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) return nfc_ls_root_get(static_cast<AHandle*>(h)->id);
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to astro");
        return push(d);
      }
    }
    return 0;
  }

  // ---- bound variables ----
  static bool same(const Var& a, const Var& b) {
    if (a.kind() != b.kind()) return false;
    switch (a.kind()) {
      case Var::Nil: return true;
      case Var::Bool: return a.b() == b.b();
      case Var::Int: return a.i() == b.i();
      case Var::Float: return a.d() == b.d() || (std::isnan(a.d()) && std::isnan(b.d()));
      case Var::Str: return a.s() == b.s();
      default: return false;
    }
  }
  void sync_in() {  // host -> script
    for (LiveVar& lv : live) {
      Var v = lv.get->invoke(nullptr, nullptr);
      nfc_ls_set_global(lv.name.c_str(), push(v));
      lv.last = v;
    }
  }
  void sync_out() {  // script -> host
    for (LiveVar& lv : live) {
      Var now = decode(nfc_ls_get_global(lv.name.c_str()));
      if (same(now, lv.last)) continue;
      lv.last = now;
      if (!lv.set) throw VarError{"NameError", "variable " + lv.name + " is read-only"};
      Var arg = now;
      lv.set->invoke(nullptr, &arg);
    }
  }
  void sync_out_quietly() {  // on the way out of a failed script, which is the error that counts
    try {
      sync_out();
    } catch (...) {
    }
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    sync_in();
    nfc_lv out = 0;
    int rc = nfc_ls_eval(code.data(), code.size(), &out);
    if (rc == 1) {
      sync_out_quietly();
      raise_script_error(this, "SyntaxError", std::string(nfc_ls_str_data(out), nfc_ls_str_len(out)), {}, true);
    }
    return finish(rc, out);
  }

  // The end of a run of script code: copies the bound variables back, then the result or the error.
  Var finish(int rc, nfc_lv out) {
    if (rc == 2) {
      sync_out_quietly();
      throw_for_error(out);
    }
    Var r = decode(out);  // before sync_out: that may run C++ that disturbs nothing, but the value is rooted by now
    try {
      sync_out();
    } catch (const VarError& e) {
      raise_script_error(this, e.cls, e.msg, {}, false);
    }
    return r;
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    nfc_lv t = nfc_ls_root_get(static_cast<AHandle*>(v.handle())->id);
    if (nfc_ls_kind(t) != NFC_TABLE || !nfc_ls_table_is_array(t)) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    std::vector<Var> out;
    long long n = nfc_ls_table_len(t);
    for (long long k = 1; k <= n; ++k) out.push_back(deep_var(decode(nfc_ls_table_geti(t, k)), depth + 1));
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override {
    sync_in();
    std::vector<nfc_lv> argv;
    argv.reserve(args.size());
    nfc_lv t = push(target);
    for (const Var& a : args) argv.push_back(push(a));
    nfc_lv out = 0;
    int rc;
    if (method.empty()) {  // the value itself is the function
      rc = nfc_ls_call(t, argv.data(), static_cast<unsigned>(argv.size()), &out);
    } else {
      rc = nfc_ls_call_method(t, method.data(), method.size(), argv.data(), static_cast<unsigned>(argv.size()), &out);
      if (rc == 3) {
        sync_out_quietly();
        raise_script_error(this, "NoMethodError", "no method '" + method + "'", {}, false);
      }
    }
    return finish(rc, out);
  }

  std::string inspect(const Var& v) override {
    nfc_lv s = nfc_ls_tostring(push(v));
    return std::string(nfc_ls_str_data(s), nfc_ls_str_len(s));
  }

  std::string type_name(const Var& v) override {
    switch (nfc_ls_kind(push(v))) {
      case NFC_NIL: return "nil";
      case NFC_BOOL: return "boolean";
      case NFC_INT: return "integer";
      case NFC_FLOAT: return "float";
      case NFC_STR: return "string";
      case NFC_TABLE: return "table";
      case NFC_FUNC: return "function";
      case NFC_THREAD: return "thread";
      default: return "unknown";
    }
  }

  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    nfc_lv t = nfc_ls_root_get(static_cast<AHandle*>(v.handle())->id);
    return nfc_ls_kind(t) == NFC_TABLE && nfc_ls_table_is_array(t);
  }

  // ---- declarations ----
  void define_fn(const std::string& name, Callable* c) override {
    // luastro's C functions carry no data, so the function is a Lua closure over one shared C function and its number. luastro
    // does not expand `...` in a call (f(...) passes the first one), so the closure has exactly arity() parameters, and one more
    // that must stay nil: a script that passes more arguments than the function takes gets the ArgumentError. A missing argument
    // is nil, and the conversion of the nil to the parameter's type is the error (TypeError) or, for an optional one, nil.
    fns.push_back(c);
    std::string params, pass = std::to_string(fns.size() - 1);
    for (int k = 0; k < c->arity(); ++k) params += "a" + std::to_string(k) + ", ";
    pass += ", " + params;
    std::string src = name + " = function(" + params + "extra) return __nfc_call(" + pass + "extra) end";
    nfc_lv out = 0;
    if (nfc_ls_eval(src.data(), src.size(), &out) != 0) throw Error("nfcpoly: astro could not define " + name);
  }
  void define_value(const std::string& name, const Var& v) override { nfc_ls_set_global(name.c_str(), push(v)); }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    live.push_back(LiveVar{name, get, set, Var()});
  }
  // luastro has no object that carries a C++ pointer: a class is declared and left out.
  void class_define(ClassInfo*) override {}
  void class_method(ClassInfo*, const std::string&, Callable*) override {}
  void class_prop(ClassInfo*, const std::string&, Callable*, Callable*) override {}
  void class_ctor(ClassInfo*, Callable*) override {}

  // ---- errors ----
  nfc_lv make_error(const std::string& cls, const std::string& msg, long host) {
    nfc_lv t = nfc_ls_mk_table(0, 3);
    nfc_ls_table_set_str(t, "class", nfc_ls_mk_str(cls.data(), cls.size()));
    nfc_ls_table_set_str(t, "message", nfc_ls_mk_str(msg.data(), msg.size()));
    if (host) nfc_ls_table_set_str(t, "host", nfc_ls_mk_int(host));
    return t;
  }

  // The host side of the script error value ERR: the original C++ exception when the script carried one out unrescued, else
  // ScriptError. Never returns.
  [[noreturn]] void throw_for_error(nfc_lv err) {
    std::string cls = "LuaError", msg;
    std::exception_ptr host;
    if (nfc_ls_kind(err) == NFC_TABLE) {
      nfc_lv c = nfc_ls_table_get_str(err, "class"), m = nfc_ls_table_get_str(err, "message"), h = nfc_ls_table_get_str(err, "host");
      if (nfc_ls_kind(c) == NFC_STR) cls.assign(nfc_ls_str_data(c), nfc_ls_str_len(c));
      if (nfc_ls_kind(m) == NFC_STR) {
        msg.assign(nfc_ls_str_data(m), nfc_ls_str_len(m));
      } else {
        nfc_lv s = nfc_ls_tostring(err);
        msg.assign(nfc_ls_str_data(s), nfc_ls_str_len(s));
      }
      if (nfc_ls_kind(h) == NFC_INT) {
        auto it = hosts.find(static_cast<long>(nfc_ls_as_int(h)));
        if (it != hosts.end()) {
          host = it->second;
          hosts.erase(it);
        }
      }
    } else {
      nfc_lv s = nfc_ls_kind(err) == NFC_STR ? err : nfc_ls_tostring(err);
      msg.assign(nfc_ls_str_data(s), nfc_ls_str_len(s));
    }
    if (host) std::rethrow_exception(host);
    nfc_ls_root_set(kLastErrRoot, err);  // so that a trampoline can raise this very value again
    raise_script_error(this, cls, msg, {}, false);
  }

  // The trampoline of every bound function: __nfc_call(id, args...) in the interpreter. Catches whatever the Callable throws and
  // returns 1 with the error value to raise; the interpreter raises it once this frame is gone.
  static int host_cb(void* user, long id, const nfc_lv* args, unsigned argc, nfc_lv* out) {
    AstroLang* self = static_cast<AstroLang*>(user);
    enum { None, Existing, Plain, Host } kind = None;
    std::string cls, msg;
    std::exception_ptr host;
    try {
      Callable* c = self->fns[static_cast<std::size_t>(id)];
      long want = c->arity();
      if (argc != static_cast<unsigned>(want) + 1) {
        kind = Plain;
        cls = "RuntimeError";
        msg = "astro: bound function called with a wrong number of internal arguments";
      } else if (nfc_ls_kind(args[want]) != NFC_NIL) {
        kind = Plain;
        cls = "ArgumentError";
        msg = "wrong number of arguments (given more than " + std::to_string(want) + ", expected " +
              (c->min_arity() != want ? std::to_string(c->min_arity()) + ".." : std::string()) + std::to_string(want) + ")";
      } else {
        self->sync_out();
        std::vector<Var> av;
        av.reserve(static_cast<std::size_t>(want));
        for (long k = 0; k < want; ++k) av.push_back(self->decode(args[k]));
        Var r = c->invoke(nullptr, av.data());
        nfc_lv lv = self->push(r);
        self->sync_in();
        *out = lv;
        return 0;
      }
    } catch (const VarError& e) {
      kind = Plain;
      cls = e.cls;
      msg = e.msg;
    } catch (const ScriptError& e) {
      if (e.owner() == self && e.serial() == self->exc_serial) {
        kind = Existing;  // the script error this came from: raise that very value again
      } else {
        kind = Plain;
        cls = "RuntimeError";
        msg = e.what();
      }
    } catch (const ConversionError& e) {
      kind = Plain;
      cls = "TypeError";
      msg = e.what();
    } catch (const std::exception& e) {
      kind = Host;
      host = std::current_exception();
      msg = e.what();
    } catch (...) {
      kind = Host;
      host = std::current_exception();
      msg = "unknown C++ exception";
    }
    if (kind == Existing) {
      *out = nfc_ls_root_get(kLastErrRoot);
    } else if (kind == Host) {
      long h = self->next_host++;
      self->hosts[h] = host;
      *out = self->make_error("NfcPoly::HostError", msg, h);
    } else {
      *out = self->make_error(cls, msg, 0);
    }
    return 1;
  }
};

AHandle::~AHandle() {
  if (lang && al) al->unroot(id);
}

std::unique_ptr<Lang> make_astro(Impl* impl) { return std::unique_ptr<Lang>(new AstroLang(impl)); }
LangRegistrar registrar("astro", "luastro", nullptr, &make_astro);

}  // namespace
}  // namespace detail
}  // namespace nfcpoly
