// nfcpoly Lua backend: Lua 5.4 with ldo.c built as C++ (scripts/setup-poly-lua.sh). See docs/notes/poly.md.
//
// A Lua error in this liblua is a C++ `throw` of a pointer to ldo.c's private struct lua_longjmp, on the same exception
// runtime as every C++ `throw` of the host. So a Lua error unwinds the C++ frames it crosses and runs their destructors,
// and a bound function's frame can let it pass: the trampoline's `catch (void*)` rethrows it.
//
// Script errors are Lua values. The backend raises its own as tables {class=, message=} with the metatable
// "nfcpoly.Error" (tostring gives "class: message"), and a host exception that entered the script carries a userdata
// holding a std::exception_ptr in the field `host`; error("text") raises a plain string, reported as class "LuaError".
extern "C" {
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
}

#include <cstdlib>
#include <cstring>
#include <map>
#include <new>

#include "nfcpoly_lang.hpp"
#include "nfcpoly_lua.hpp"

namespace nfcpoly {
namespace detail {

namespace {

struct LuaLang;

struct LuaObj {  // the userdata of a bound class instance
  ClassInfo* ci;
  void* p;
  Owned* own;
};

struct LHandle : Handle {
  lua_State* L;
  int ref;
  LHandle(Lang* l, Impl* i, lua_State* s, int r) : Handle(l, i), L(s), ref(r) {}
  ~LHandle() override {
    if (lang && L) luaL_unref(L, LUA_REGISTRYINDEX, ref);
  }
  void orphan() override { L = nullptr; }
};

struct LiveVar {
  Callable* get;
  Callable* set;
};

// Internal metatable names use a colon, class metatables are "nfcpoly.class.<Name>": a bound class named Error cannot clash.
const char* const kErrorMeta = "nfcpoly:Error";
const char* const kHostMeta = "nfcpoly:HostExc";
const char* const kClassMetaPrefix = "nfcpoly.class.";
const char* const kLastErr = "nfcpoly.lasterr";
const char* const kLastTb = "nfcpoly.lasttb";

struct StackGuard {
  lua_State* L;
  int top;
  explicit StackGuard(lua_State* s) : L(s), top(lua_gettop(s)) {}
  ~StackGuard() { lua_settop(L, top); }
};

LuaLang* lang_of(lua_State* L);

bool is_error_table(lua_State* L, int idx) {  // a table made by push_error
  if (lua_type(L, idx) != LUA_TTABLE || !lua_getmetatable(L, idx)) return false;
  luaL_getmetatable(L, kErrorMeta);
  bool same = lua_rawequal(L, -1, -2) != 0;
  lua_pop(L, 2);
  return same;
}

int fn_tramp(lua_State* L);
int method_tramp(lua_State* L);
int ctor_call(lua_State* L);
int obj_index(lua_State* L);
int obj_newindex(lua_State* L);
int obj_gc(lua_State* L);
int obj_tostring(lua_State* L);
int obj_arith(lua_State* L);
// The operators a class can define: the Lua metamethod, the method for `obj OP x`, the method for `x OP obj` (null for a
// unary operator). Not the comparisons: Lua turns the result of __eq, __lt and __le into a boolean, so a method cannot
// return a value there.
struct LuaOpName {
  const char* meta;
  const char* fwd;
  const char* rev;
};
const LuaOpName kLuaOp[] = {{"__add", "__add__", "__radd__"},   {"__sub", "__sub__", "__rsub__"},
                            {"__mul", "__mul__", "__rmul__"},   {"__div", "__truediv__", "__rtruediv__"},
                            {"__mod", "__mod__", "__rmod__"},   {"__idiv", "__floordiv__", "__rfloordiv__"},
                            {"__band", "__and__", "__rand__"},  {"__bor", "__or__", "__ror__"},
                            {"__bxor", "__xor__", "__rxor__"},  {"__unm", "__neg__", nullptr}};
constexpr int kLuaOps = sizeof(kLuaOp) / sizeof(kLuaOp[0]);
int live_index(lua_State* L);
int live_newindex(lua_State* L);
int msgh(lua_State* L);
int err_tostring(lua_State* L);
int host_gc(lua_State* L);

// ---- errors raised into Lua ---------------------------------------------------------------------------------------
void push_error(lua_State* L, const std::string& cls, const std::string& msg) {
  lua_createtable(L, 0, 3);
  lua_pushlstring(L, cls.data(), cls.size());
  lua_setfield(L, -2, "class");
  lua_pushlstring(L, msg.data(), msg.size());
  lua_setfield(L, -2, "message");
  luaL_setmetatable(L, kErrorMeta);
}

[[noreturn]] void raise_error(lua_State* L, const std::string& cls, const std::string& msg) {
  push_error(L, cls, msg);
  lua_error(L);
  std::abort();  // not reached: lua_error throws
}

// What the trampoline raises once the C++ handlers have finished (building script values inside them could itself raise).
struct Pending {
  enum Kind { None, Existing, Plain, Host } kind = None;
  std::string cls, msg;
  std::exception_ptr host;
};

[[noreturn]] void raise_pending(lua_State* L, Pending& p) {
  if (p.kind == Pending::Existing) {
    lua_getfield(L, LUA_REGISTRYINDEX, kLastErr);
    lua_error(L);
  }
  if (p.kind == Pending::Host) {
    push_error(L, "NfcPoly::HostError", p.msg);
    void* mem = lua_newuserdatauv(L, sizeof(std::exception_ptr), 0);
    new (mem) std::exception_ptr(p.host);
    luaL_setmetatable(L, kHostMeta);
    lua_setfield(L, -2, "host");
    lua_error(L);
  }
  raise_error(L, p.cls, p.msg);
}

struct CurGuard {  // the thread a bound function runs on is the thread a callback into the interpreter must use
  LuaLang* lang;
  lua_State* saved;
  CurGuard(LuaLang* l, lua_State* now);
  ~CurGuard();
};

// ---- the language ---------------------------------------------------------------------------------------------------
struct LuaLang : Lang {
  lua_State* main = nullptr;
  lua_State* cur = nullptr;
  std::map<ClassInfo*, std::string> metas;  // class -> metatable name in the registry
  std::map<std::string, LiveVar> live;      // bound variables, read and written through the globals' metatable
  bool live_installed = false;

  explicit LuaLang(Impl* i) : Lang(i) {
    main = luaL_newstate();
    if (!main) throw Error("nfcpoly: luaL_newstate failed (out of memory)");
    cur = main;
    *static_cast<LuaLang**>(lua_getextraspace(main)) = this;
    // The libraries that give a script no files, no os.exit and no clock: base (minus dofile/loadfile), coroutine, table,
    // string, math, utf8.
    luaL_requiref(main, "_G", luaopen_base, 1);
    lua_pop(main, 1);
    luaL_requiref(main, LUA_COLIBNAME, luaopen_coroutine, 1);
    lua_pop(main, 1);
    luaL_requiref(main, LUA_TABLIBNAME, luaopen_table, 1);
    lua_pop(main, 1);
    luaL_requiref(main, LUA_STRLIBNAME, luaopen_string, 1);
    lua_pop(main, 1);
    luaL_requiref(main, LUA_MATHLIBNAME, luaopen_math, 1);
    lua_pop(main, 1);
    luaL_requiref(main, LUA_UTF8LIBNAME, luaopen_utf8, 1);
    lua_pop(main, 1);
    lua_pushnil(main);
    lua_setglobal(main, "dofile");
    lua_pushnil(main);
    lua_setglobal(main, "loadfile");
    luaL_newmetatable(main, kErrorMeta);
    lua_pushcfunction(main, err_tostring);
    lua_setfield(main, -2, "__tostring");
    lua_pop(main, 1);
    luaL_newmetatable(main, kHostMeta);
    lua_pushcfunction(main, host_gc);
    lua_setfield(main, -2, "__gc");
    lua_pop(main, 1);
  }
  ~LuaLang() override {
    if (main) lua_close(main);  // runs the finalizers of script-owned C++ objects
  }
  const char* name() const override { return "lua"; }

  // ---- values ----
  Var handle_of(lua_State* L, int idx) {
    lua_pushvalue(L, idx);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return Var::script(new LHandle(this, impl, main, ref));
  }

  Var decode(lua_State* L, int idx) {  // shallow
    idx = lua_absindex(L, idx);
    Var r;
    switch (lua_type(L, idx)) {
      case LUA_TNIL: break;
      case LUA_TBOOLEAN: r = Var::boolean(lua_toboolean(L, idx) != 0); break;
      case LUA_TNUMBER:
        if (lua_isinteger(L, idx)) r = Var::integer(static_cast<long long>(lua_tointeger(L, idx)));
        else r = Var::real(static_cast<double>(lua_tonumber(L, idx)));
        break;
      case LUA_TSTRING: {
        std::size_t n = 0;
        const char* s = lua_tolstring(L, idx, &n);
        r = Var::string(std::string(s, n));
        break;
      }
      case LUA_TUSERDATA: {
        LuaObj* o = object_at(L, idx);
        if (o) r = Var::object(o->ci, o->p, o->own);
        else r = handle_of(L, idx);
        break;
      }
      default: r = handle_of(L, idx); break;  // table, function, thread, light userdata
    }
    r.set_src(this);
    return r;
  }

  LuaObj* object_at(lua_State* L, int idx) {  // the LuaObj of a bound class instance, else null
    if (lua_type(L, idx) != LUA_TUSERDATA || !lua_getmetatable(L, idx)) return nullptr;
    lua_getfield(L, -1, "__name");
    const char* n = lua_tostring(L, -1);
    bool ours = n && std::strncmp(n, kClassMetaPrefix, std::strlen(kClassMetaPrefix)) == 0;
    lua_pop(L, 2);
    return ours ? static_cast<LuaObj*>(lua_touserdata(L, idx)) : nullptr;
  }

  void push(lua_State* L, const Var& v) {
    luaL_checkstack(L, 6, "nfcpoly: too many nested values");
    switch (v.kind()) {
      case Var::Nil: lua_pushnil(L); break;
      case Var::Bool: lua_pushboolean(L, v.b() ? 1 : 0); break;
      case Var::Int: lua_pushinteger(L, static_cast<lua_Integer>(v.i())); break;
      case Var::Float: lua_pushnumber(L, static_cast<lua_Number>(v.d())); break;
      case Var::Str: lua_pushlstring(L, v.s().data(), v.s().size()); break;
      case Var::Arr: {
        lua_createtable(L, static_cast<int>(v.a().size()), 0);
        lua_Integer k = 1;
        for (const Var& e : v.a()) {
          push(L, e);
          lua_rawseti(L, -2, k++);
        }
        break;
      }
      case Var::Obj: {
        auto it = metas.find(v.ci());
        if (it == metas.end()) throw ConversionError("nfcpoly: class " + v.ci()->name + " is not defined in lua");
        LuaObj* o = static_cast<LuaObj*>(lua_newuserdatauv(L, sizeof(LuaObj), 0));
        o->ci = v.ci();
        o->p = v.ptr();
        o->own = v.owned();
        if (o->own) owned_ref(o->own);
        luaL_setmetatable(L, it->second.c_str());
        break;
      }
      case Var::Script: {
        Handle* h = v.handle();
        if (!h->lang) throw ConversionError("nfcpoly: a script value whose interpreter is gone");
        if (h->lang == this) {
          lua_rawgeti(L, LUA_REGISTRYINDEX, static_cast<LHandle*>(h)->ref);
          break;
        }
        Var d = h->lang->to_var(v);  // from another language: by copy where it can be
        if (d.kind() == Var::Script)
          throw ConversionError(std::string("nfcpoly: a ") + h->lang->name() + " value cannot be passed to lua");
        push(L, d);
        break;
      }
    }
  }

  static bool table_is_array(lua_State* L, int idx) {
    idx = lua_absindex(L, idx);
    lua_Integer n = static_cast<lua_Integer>(lua_rawlen(L, idx));
    lua_Integer count = 0;
    lua_pushnil(L);
    while (lua_next(L, idx)) {
      if (!lua_isinteger(L, -2)) {
        lua_pop(L, 2);
        return false;
      }
      lua_Integer key = lua_tointeger(L, -2);
      ++count;
      lua_pop(L, 1);
      if (key < 1 || key > n) {
        lua_pop(L, 1);
        return false;
      }
    }
    return count == n;
  }

  // ---- Lang ----
  Var eval(std::string_view code) override {
    lua_State* L = cur;
    StackGuard guard(L);
    // A source that is a single expression returns its value: try it as `return <code>` first, then as statements.
    std::string expr = "return " + std::string(code);
    int st = luaL_loadbufferx(L, expr.data(), expr.size(), "=snippet", "t");
    if (st != LUA_OK) {
      lua_pop(L, 1);
      st = luaL_loadbufferx(L, code.data(), code.size(), "=snippet", "t");
      if (st != LUA_OK) {
        std::string msg = lua_tostring(L, -1) ? lua_tostring(L, -1) : "syntax error";
        raise_script_error(this, "SyntaxError", msg, std::vector<std::string>(), true);
      }
    }
    st = pcall_msgh(L, 0, 1);
    if (st != LUA_OK) throw_for_error(L, st);
    return decode(L, -1);
  }

  Var to_var(const Var& v) override { return deep_var(v, 0); }

  Var deep_var(const Var& v, int depth) {
    if (v.kind() != Var::Script || v.handle()->lang != this) return v;
    lua_State* L = cur;
    StackGuard guard(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, static_cast<LHandle*>(v.handle())->ref);
    if (lua_type(L, -1) != LUA_TTABLE || !table_is_array(L, -1)) return v;
    if (depth > 100) throw ConversionError("nfcpoly: array nested too deeply (or cyclic)");
    std::vector<Var> out;
    lua_Integer n = static_cast<lua_Integer>(lua_rawlen(L, -1));
    for (lua_Integer k = 1; k <= n; ++k) {
      lua_rawgeti(L, -1, k);
      out.push_back(deep_var(decode(L, -1), depth + 1));
      lua_pop(L, 1);
    }
    Var r = Var::array(std::move(out));
    r.set_src(this);
    return r;
  }

  Var call(const Var& target, const std::string& method, const std::vector<Var>& args) override;

  std::string inspect(const Var& v) override {
    lua_State* L = cur;
    StackGuard guard(L);
    lua_pushcfunction(L, [](lua_State* S) -> int {
      std::size_t n = 0;
      const char* s = luaL_tolstring(S, 1, &n);
      lua_pushlstring(S, s, n);
      return 1;
    });
    push(L, v);
    if (pcall_msgh(L, 1, 1) == LUA_OK && lua_type(L, -1) == LUA_TSTRING) {
      std::size_t n = 0;
      const char* s = lua_tolstring(L, -1, &n);
      return std::string(s, n);
    }
    return type_name(v);
  }

  std::string type_name(const Var& v) override {
    lua_State* L = cur;
    StackGuard guard(L);
    push(L, v);
    if (lua_type(L, -1) == LUA_TNUMBER) return lua_isinteger(L, -1) ? "integer" : "float";
    return luaL_typename(L, -1);
  }

  bool is_array(const Var& v) override {
    if (v.kind() != Var::Script || v.handle()->lang != this) return false;
    lua_State* L = cur;
    StackGuard guard(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, static_cast<LHandle*>(v.handle())->ref);
    return lua_type(L, -1) == LUA_TTABLE && table_is_array(L, -1);
  }

  // ---- declarations ----
  void define_fn(const std::string& name, Callable* c) override {
    lua_pushlightuserdata(main, c);
    lua_pushcclosure(main, fn_tramp, 1);
    lua_setglobal(main, name.c_str());
  }
  void define_value(const std::string& name, const Var& v) override {
    StackGuard guard(main);
    push(main, v);
    lua_setglobal(main, name.c_str());
  }
  void define_variable(const std::string& name, Callable* get, Callable* set) override {
    live[name] = LiveVar{get, set};
    if (live_installed) return;
    live_installed = true;
    StackGuard guard(main);
    lua_pushglobaltable(main);
    lua_createtable(main, 0, 2);
    lua_pushcfunction(main, live_index);
    lua_setfield(main, -2, "__index");
    lua_pushcfunction(main, live_newindex);
    lua_setfield(main, -2, "__newindex");
    lua_setmetatable(main, -2);
  }
  void class_define(ClassInfo* ci) override {
    StackGuard guard(main);
    std::string mt = std::string(kClassMetaPrefix) + ci->name;
    luaL_newmetatable(main, mt.c_str());
    lua_pushcfunction(main, obj_index);
    lua_setfield(main, -2, "__index");
    lua_pushcfunction(main, obj_newindex);
    lua_setfield(main, -2, "__newindex");
    lua_pushcfunction(main, obj_gc);
    lua_setfield(main, -2, "__gc");
    lua_pushcfunction(main, obj_tostring);
    lua_setfield(main, -2, "__tostring");
    // Arithmetic and bitwise operators call the class's Python-named methods (__add__, __radd__, ...; "Operators" in poly.md).
    for (int k = 0; k < kLuaOps; ++k) {
      lua_pushinteger(main, k);
      lua_pushcclosure(main, obj_arith, 1);
      lua_setfield(main, -2, kLuaOp[k].meta);
    }
    metas[ci] = mt;
    lua_newtable(main);  // the class table: Name.new(...) and Name(...)
    lua_setglobal(main, ci->name.c_str());
  }
  void class_method(ClassInfo*, const std::string&, Callable*) override {}  // looked up in ClassInfo on each access
  void class_prop(ClassInfo*, const std::string&, Callable*, Callable*) override {}
  void class_ctor(ClassInfo* ci, Callable* c) override {
    StackGuard guard(main);
    lua_getglobal(main, ci->name.c_str());
    lua_pushlightuserdata(main, c);
    lua_pushcclosure(main, fn_tramp, 1);
    lua_setfield(main, -2, "new");
    lua_createtable(main, 0, 1);
    lua_pushlightuserdata(main, c);
    lua_pushcclosure(main, ctor_call, 1);
    lua_setfield(main, -2, "__call");
    lua_setmetatable(main, -2);
  }

  // ---- errors ----
  // Calls the function and its nargs arguments on top of the stack in protected mode with a message handler that records
  // the traceback. Leaves the results (or the error value) in place of the function.
  int pcall_msgh(lua_State* L, int nargs, int nres) {
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, msgh);
    lua_insert(L, base);
    int st = lua_pcall(L, nargs, nres, base);
    lua_remove(L, base);
    return st;
  }

  // The host side of the error value on top of the stack: the original C++ exception when the script carried one out
  // unrescued, else ScriptError. Never returns.
  [[noreturn]] void throw_for_error(lua_State* L, int status) {
    std::string cls = "LuaError", msg;
    std::exception_ptr host;
    if (is_error_table(L, -1)) {
      lua_getfield(L, -1, "class");
      if (lua_type(L, -1) == LUA_TSTRING) cls = lua_tostring(L, -1);
      lua_pop(L, 1);
      lua_getfield(L, -1, "message");
      if (lua_type(L, -1) == LUA_TSTRING) msg = lua_tostring(L, -1);
      lua_pop(L, 1);
      lua_getfield(L, -1, "host");
      if (void* h = luaL_testudata(L, -1, kHostMeta)) host = *static_cast<std::exception_ptr*>(h);
      lua_pop(L, 1);
    } else if (lua_type(L, -1) == LUA_TSTRING) {
      msg = lua_tostring(L, -1);
    } else {
      std::size_t n = 0;
      const char* s = luaL_tolstring(L, -1, &n);
      msg.assign(s, n);
      lua_pop(L, 1);
    }
    if (host) std::rethrow_exception(host);
    if (status == LUA_ERRMEM) cls = "MemoryError";
    std::vector<std::string> bt;
    lua_getfield(L, LUA_REGISTRYINDEX, kLastTb);
    if (lua_type(L, -1) == LUA_TSTRING) {
      std::string tb = lua_tostring(L, -1);
      std::size_t pos = 0;
      while (pos < tb.size()) {
        std::size_t e = tb.find('\n', pos);
        if (e == std::string::npos) e = tb.size();
        std::string line = tb.substr(pos, e - pos);
        if (!line.empty() && line != "stack traceback:") bt.push_back(line.substr(line.find_first_not_of("\t ")));
        pos = e + 1;
      }
    }
    lua_pop(L, 1);
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, kLastErr);  // so that a trampoline can raise this very value again
    raise_script_error(this, cls, msg, std::move(bt), false);
  }
};

LuaLang* lang_of(lua_State* L) { return *static_cast<LuaLang**>(lua_getextraspace(L)); }

CurGuard::CurGuard(LuaLang* l, lua_State* now) : lang(l), saved(l->cur) { l->cur = now; }
CurGuard::~CurGuard() { lang->cur = saved; }

// Calls c with arguments taken from the stack (all of it): mode 0 a plain function, mode 1 a method whose receiver is slot 1.
// Pushes the result and returns 1; a C++ exception becomes a Lua error, raised after the handlers have finished.
int run_callable(lua_State* L, Callable* c, int mode) {
  LuaLang* lang = lang_of(L);
  int nargs = lua_gettop(L);
  int self_slots = mode == 1 ? 1 : 0;
  if (!arity_fits(c, nargs - self_slots)) raise_error(L, "ArgumentError", arity_message(c, nargs - self_slots));
  CurGuard cur(lang, L);
  Pending pend;
  try {
    std::vector<Var> args;
    args.reserve(static_cast<std::size_t>(nargs));
    for (int k = self_slots + 1; k <= nargs; ++k) args.push_back(lang->decode(L, k));
    arity_pad(c, args);
    Var selfv;
    const Var* sp = nullptr;
    if (mode == 1) {
      selfv = lang->decode(L, 1);
      sp = &selfv;
    }
    Var r = c->invoke(sp, args.data());
    lang->push(L, r);
    return 1;
  } catch (void*) {
    throw;  // a Lua error passing through on its way to a pcall (Lua throws a pointer to its private struct lua_longjmp)
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
  raise_pending(L, pend);
  return 0;  // not reached
}

int fn_tramp(lua_State* L) { return run_callable(L, static_cast<Callable*>(lua_touserdata(L, lua_upvalueindex(1))), 0); }
int method_tramp(lua_State* L) { return run_callable(L, static_cast<Callable*>(lua_touserdata(L, lua_upvalueindex(1))), 1); }

int ctor_call(lua_State* L) {  // Name(...): the class table is slot 1
  lua_remove(L, 1);
  return run_callable(L, static_cast<Callable*>(lua_touserdata(L, lua_upvalueindex(1))), 0);
}

int obj_index(lua_State* L) {  // (object, key)
  LuaObj* o = static_cast<LuaObj*>(lua_touserdata(L, 1));
  if (lua_type(L, 2) != LUA_TSTRING) {
    lua_pushnil(L);
    return 1;
  }
  std::string key = lua_tostring(L, 2);
  for (const ClassInfo::Prop& p : o->ci->props) {
    if (p.name == key) {
      lua_settop(L, 1);
      return run_callable(L, p.get, 1);
    }
  }
  for (auto& m : o->ci->methods) {
    if (m.first == key) {
      lua_pushlightuserdata(L, m.second);
      lua_pushcclosure(L, method_tramp, 1);
      return 1;
    }
  }
  lua_pushnil(L);
  return 1;
}

int obj_newindex(lua_State* L) {  // (object, key, value)
  LuaObj* o = static_cast<LuaObj*>(lua_touserdata(L, 1));
  if (lua_type(L, 2) == LUA_TSTRING) {
    std::string key = lua_tostring(L, 2);
    for (const ClassInfo::Prop& p : o->ci->props) {
      if (p.name == key) {
        if (!p.set) raise_error(L, "AttributeError", "field " + key + " of " + o->ci->name + " is read-only");
        lua_remove(L, 2);
        run_callable(L, p.set, 1);
        return 0;
      }
    }
  }
  raise_error(L, "AttributeError", o->ci->name + " has no field to assign");
}

int obj_gc(lua_State* L) {
  LuaObj* o = static_cast<LuaObj*>(lua_touserdata(L, 1));
  if (o->own) {
    owned_unref(o->own);
    o->own = nullptr;
  }
  return 0;
}

int obj_tostring(lua_State* L) {
  LuaObj* o = static_cast<LuaObj*>(lua_touserdata(L, 1));
  for (auto& m : o->ci->methods) {
    if (m.first == "__str__") {
      lua_settop(L, 1);
      return run_callable(L, m.second, 1);
    }
  }
  lua_pushstring(L, (o->ci->name + " object").c_str());
  return 1;
}

Callable* method_of_operand(lua_State* L, int idx, const char* name) {  // the method NAME of the bound object at idx, else null
  LuaObj* o = lang_of(L)->object_at(L, idx);
  if (!o) return nullptr;
  for (auto& m : o->ci->methods)
    if (m.first == name) return m.second;
  return nullptr;
}

int obj_arith(lua_State* L) {  // (a, b); upvalue 1: the index in kLuaOp; either operand is the object
  const LuaOpName& op = kLuaOp[lua_tointeger(L, lua_upvalueindex(1))];
  if (!op.rev) {  // unary: Lua passes the operand twice
    lua_settop(L, 1);
    if (Callable* c = method_of_operand(L, 1, op.fwd)) return run_callable(L, c, 1);
  } else {
    lua_settop(L, 2);
    if (Callable* c = method_of_operand(L, 1, op.fwd)) return run_callable(L, c, 1);
    if (Callable* c = method_of_operand(L, 2, op.rev)) {
      lua_pushvalue(L, 1);  // (a, b) -> (b, a)
      lua_remove(L, 1);
      return run_callable(L, c, 1);
    }
  }
  raise_error(L, "TypeError", std::string("attempt to perform arithmetic on a ") + luaL_typename(L, 1) + " value");
}

int live_index(lua_State* L) {  // (_G, key): a bound variable reads live
  LuaLang* lang = lang_of(L);
  if (lua_type(L, 2) == LUA_TSTRING) {
    auto it = lang->live.find(lua_tostring(L, 2));
    if (it != lang->live.end()) {
      lua_settop(L, 0);
      return run_callable(L, it->second.get, 0);
    }
  }
  lua_pushnil(L);
  return 1;
}

int live_newindex(lua_State* L) {  // (_G, key, value): a bound variable writes through
  LuaLang* lang = lang_of(L);
  if (lua_type(L, 2) == LUA_TSTRING) {
    auto it = lang->live.find(lua_tostring(L, 2));
    if (it != lang->live.end()) {
      if (!it->second.set) raise_error(L, "NameError", std::string("variable ") + lua_tostring(L, 2) + " is read-only");
      lua_remove(L, 1);
      lua_remove(L, 1);
      run_callable(L, it->second.set, 0);
      return 0;
    }
  }
  lua_rawset(L, 1);
  return 0;
}

int msgh(lua_State* L) {
  luaL_traceback(L, L, nullptr, 1);
  lua_setfield(L, LUA_REGISTRYINDEX, kLastTb);
  lua_settop(L, 1);
  return 1;
}

int err_tostring(lua_State* L) {
  lua_getfield(L, 1, "class");
  lua_pushstring(L, ": ");
  lua_getfield(L, 1, "message");
  lua_concat(L, 3);
  return 1;
}

int host_gc(lua_State* L) {
  using EP = std::exception_ptr;
  static_cast<EP*>(lua_touserdata(L, 1))->~EP();
  return 0;
}

int call_helper(lua_State* L) {  // (target, name, args...): target[name](target, args...)
  int n = lua_gettop(L);
  lua_pushvalue(L, 2);
  lua_gettable(L, 1);
  if (lua_isnil(L, -1)) raise_error(L, "NoMethodError", std::string("no method '") + lua_tostring(L, 2) + "'");
  lua_pushvalue(L, 1);
  for (int k = 3; k <= n; ++k) lua_pushvalue(L, k);
  lua_call(L, n - 1, 1);
  return 1;
}

Var LuaLang::call(const Var& target, const std::string& method, const std::vector<Var>& args) {
  lua_State* L = cur;
  StackGuard guard(L);
  luaL_checkstack(L, static_cast<int>(args.size()) + 6, "nfcpoly: too many arguments");
  int st;
  if (method.empty()) {  // the value itself is the function
    push(L, target);
    for (const Var& a : args) push(L, a);
    st = pcall_msgh(L, static_cast<int>(args.size()), 1);
  } else {
    lua_pushcfunction(L, call_helper);
    push(L, target);
    lua_pushlstring(L, method.data(), method.size());
    for (const Var& a : args) push(L, a);
    st = pcall_msgh(L, static_cast<int>(args.size()) + 2, 1);
  }
  if (st != LUA_OK) throw_for_error(L, st);
  return decode(L, -1);
}

std::unique_ptr<Lang> make_lua(Impl* impl) { return std::unique_ptr<Lang>(new LuaLang(impl)); }
LangRegistrar registrar("lua", nullptr, nullptr, &make_lua);

}  // namespace
}  // namespace detail

lua_State* lua_state(Context& ctx) { return static_cast<detail::LuaLang*>(detail::get_lang(ctx.impl(), "lua"))->cur; }

void lua_push_value(lua_State* L, const Value& v) {
  const detail::Var& var = v.var();
  detail::Lang* l = var.kind() == detail::Var::Script ? var.handle()->lang : var.src();
  if (!l) throw Error("nfcpoly: the Value has no live interpreter");
  if (std::strcmp(l->name(), "lua") != 0) throw Error("nfcpoly: lua_push_value of a value from another language");
  static_cast<detail::LuaLang*>(l)->push(L, var);
}

}  // namespace nfcpoly
