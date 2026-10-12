// nfcpoly host test: exit status 0 when every check passes. Run by tests/poly/run.sh, which builds it with nfcxx together
// with lib/poly/nfcpoly.cpp and the language backends it defines TEST_RUBY / TEST_LUA / TEST_PYTHON / TEST_AST / TEST_JS / TEST_GO for.
//
// The checks that every language must pass are written once and run per language through the snippet builders of Lg;
// what only one language can express follows, then the checks that share one Context between languages.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "nfcpoly.hpp"
#ifdef TEST_RUBY
#include "nfcpoly_mruby.hpp"
#endif
#ifdef TEST_LUA
#include "nfcpoly_lua.hpp"
#endif
#ifdef TEST_PYTHON
#include "nfcpoly_python.hpp"
#endif
#ifdef TEST_AST
#include "nfcpoly_ast.hpp"
#endif
#ifdef TEST_JS
#include "nfcpoly_js.hpp"
#endif
#ifdef TEST_GO
#include <unistd.h>

#include <fstream>
#include <thread>

#include "nfcpoly_go.hpp"
#endif

using nfcpoly::Context;
using nfcpoly::Value;

static int failures = 0, checks = 0;
static const char* g_lang = "";
#define CHECK(c)                                                                  \
  do {                                                                            \
    ++checks;                                                                     \
    if (!(c)) {                                                                   \
      std::printf("FAIL [%s] line %d: %s\n", g_lang, __LINE__, #c);               \
      ++failures;                                                                 \
    }                                                                             \
  } while (0)

// ---- host types -----------------------------------------------------------------------------------------------
struct Vec3 {
  double x, y, z;
  static int live;  // constructed minus destroyed: tells whether the script's GC released script-owned objects
  Vec3() : x(0), y(0), z(0) { ++live; }
  Vec3(double a, double b, double c) : x(a), y(b), z(c) { ++live; }
  Vec3(const Vec3& o) : x(o.x), y(o.y), z(o.z) { ++live; }
  Vec3& operator=(const Vec3& o) { x = o.x; y = o.y; z = o.z; return *this; }
  ~Vec3() { --live; }
  double len2() const { return x * x + y * y + z * z; }
  void scale(double k) { x *= k; y *= k; z *= k; }
  double dot(const Vec3& o) const { return x * o.x + y * o.y + z * o.z; }
  Vec3 plus(const Vec3& o) const { return Vec3(x + o.x, y + o.y, z + o.z); }
};
int Vec3::live = 0;

struct Line {  // members of a registered class type are shared with their owner
  Vec3 a, b;
};

struct Person {
  std::string name;
  int age;
  Person(std::string n, int a) : name(std::move(n)), age(a) {}
  std::string greet(const std::string& other) const { return "hello " + other + ", I am " + name; }
};

struct Unregistered {
  int v = 1;
};

struct HostFail : std::runtime_error {  // a host exception with a payload, to see the same object come back
  int code;
  HostFail(const char* m, int c) : std::runtime_error(m), code(c) {}
};

struct Guard {  // RAII: destroyed means the C++ frame holding it was unwound
  static int alive, destroyed;
  Guard() { ++alive; }
  ~Guard() { --alive; ++destroyed; }
};
int Guard::alive = 0;
int Guard::destroyed = 0;

static double scale_fn(double v) { return v * 10.0; }
static std::string shout(std::string s) { return s + "!"; }
static int total(const std::vector<int>& xs) { int t = 0; for (int x : xs) t += x; return t; }
static std::optional<int> half(int x) { if (x % 2) return std::nullopt; return x / 2; }
static std::size_t length_of(std::string_view s) { return s.size(); }

template <class Ex, class F>
static bool throws(F f) {
  try {
    f();
  } catch (const Ex&) {
    return true;
  }
  return false;
}

// Go has no single-quoted strings, and the snippets of the shared checks write 'text': a Go snippet gets "text" instead
// (an apostrophe inside a double-quoted string is left alone).
static std::string go_quotes(std::string_view s) {
  std::string out;
  for (std::size_t k = 0; k < s.size(); ++k) {
    char c = s[k];
    if (c == '"') {
      out += c;
      for (++k; k < s.size(); ++k) {
        out += s[k];
        if (s[k] == '\\' && k + 1 < s.size()) out += s[++k];
        else if (s[k] == '"') break;
      }
    } else {
      out += c == '\'' ? '"' : c;
    }
  }
  return out;
}
struct TCtx : Context {
  static std::string src(std::string_view lang, std::string_view code) { return lang == "go" ? go_quotes(code) : std::string(code); }
  Value eval_value(std::string_view l, std::string_view c) { return Context::eval_value(l, src(l, c)); }
  void eval_void(std::string_view l, std::string_view c) { Context::eval_void(l, src(l, c)); }
  template <class R>
  R eval(std::string_view l, std::string_view c) {
    if constexpr (std::is_void_v<R>) Context::template eval<R>(l, src(l, c));
    else return Context::template eval<R>(l, src(l, c));
  }
};

// ---- one language's way of writing things -----------------------------------------------------------------------
enum Kind { Ruby, Lua, Python, Ast, Js, Go };  // Ast: Lua syntax, run by the nfcast engine
struct Lg {
  Kind k;
  std::string name;
  bool rb() const { return k == Ruby; }
  bool lu() const { return k == Lua || k == Ast; }  // Lua syntax
  bool py() const { return k == Python; }
  bool js() const { return k == Js; }
  bool go() const { return k == Go; }
  const char* ln() const { return name.c_str(); }

  std::string nil() const { return py() ? "None" : js() ? "null" : "nil"; }
  std::string list(const std::string& items) const {
    if (go()) return go_list(items);
    return lu() ? "{" + items + "}" : "[" + items + "]";
  }
  std::string ctor(const std::string& cls, const std::string& args) const {
    if (go()) return "New" + cls + "(" + args + ")";
    return py() ? cls + "(" + args + ")" : js() ? "new " + cls + "(" + args + ")" : cls + ".new(" + args + ")";
  }
  std::string call0(const std::string& obj, const std::string& m) const {
    if (go()) return obj + "." + go_name(m) + "()";
    return rb() ? obj + "." + m : lu() ? obj + ":" + m + "()" : obj + "." + m + "()";
  }
  std::string call1(const std::string& obj, const std::string& m, const std::string& a) const {
    if (go()) return obj + "." + go_name(m) + "(" + a + ")";
    return lu() ? obj + ":" + m + "(" + a + ")" : obj + "." + m + "(" + a + ")";
  }
  std::string fcall0(const std::string& f) const { return rb() ? f : f + "()"; }
  std::string setvar(const std::string& n, const std::string& v) const { return rb() ? "self." + n + " = " + v : n + " = " + v; }
  std::string concat(const std::string& a, const std::string& b) const { return lu() ? a + " .. " + b : a + " + " + b; }
  std::string gref(const std::string& n) const { return rb() ? "$" + n : n; }  // a script global
  // The error message / class name of EXPR, or nil when it raises nothing. EXPR must be an expression.
  std::string guard_msg(const std::string& e) const {
    if (go()) return "errmsg(func() { _ = " + e + " })";
    return rb() ? "errmsg { " + e + " }" : lu() ? "errmsg(function() return " + e + " end)"
           : js() ? "errmsg(() => " + e + ")" : "errmsg(lambda: " + e + ")";
  }
  std::string guard_cls(const std::string& e) const {
    if (go()) return "errcls(func() { _ = " + e + " })";
    return rb() ? "errcls { " + e + " }" : lu() ? "errcls(function() return " + e + " end)"
           : js() ? "errcls(() => " + e + ")" : "errcls(lambda: " + e + ")";
  }

  std::string str_rep() const {
    if (go()) return "strings.Repeat(\"ab\", 3)";
    return lu() ? "('ab'):rep(3)" : js() ? "'ab'.repeat(3)" : "'ab' * 3";
  }
  std::string nul_string() const {
    if (go()) return "\"a\\x00b\"";
    return "\"a\\0b\"";
  }
  std::string pow40() const {
    if (go()) return "1 << 40";
    return lu() ? "1 << 40" : "2**40";
  }
  std::string array_class() const {
    if (go()) return "[]int";
    return rb() ? "Array" : lu() ? "table" : js() ? "Array" : "list";
  }
  std::string upper() const { return rb() ? "upcase" : js() ? "toUpperCase" : "upper"; }
  std::string raise_boom() const {
    if (go()) return "panic(\"boom\")";
    return rb() ? "raise ArgumentError, 'boom'" : lu() ? "error('boom')" : js() ? "throw new Error('boom')" : "raise ValueError('boom')";
  }
  std::string err_class() const {
    if (go()) return "panic";
    return rb() ? "ArgumentError" : lu() ? "LuaError" : js() ? "Error" : "ValueError";
  }
  std::string raiser_class() const {
    if (go()) return "panic";
    return rb() ? "RuntimeError" : lu() ? "LuaError" : js() ? "Error" : "ValueError";
  }
  std::string zero_div() const {  // JavaScript's 1 / 0 is Infinity
    if (go()) return "func() int { z := 0; return 1 / z }()";  // a constant 1 / 0 does not compile
    return lu() ? "1 // 0" : js() ? "1n / 0n" : "1 / 0";
  }
  std::string zero_div_class() const {
    if (go()) return "runtime.Error";
    return lu() ? "LuaError" : js() ? "RangeError" : "ZeroDivisionError";
  }
  std::string nil_call() const {
    if (go()) return "func() int { var m map[string]int; m[\"a\"] = 1; return 0 }()";  // a write to a nil map
    return rb() ? "nil.foo" : lu() ? "local t = nil; return t.foo" : js() ? "null.foo" : "None.foo";
  }
  std::string nil_call_class() const {
    if (go()) return "runtime.Error";
    return rb() ? "NoMethodError" : lu() ? "LuaError" : js() ? "TypeError" : "AttributeError";
  }
  std::string host_cls() const {
    if (go()) return "HostError";
    return py() ? "HostError" : "NfcPoly::HostError";
  }
  std::string noop() const {
    if (go()) return "func() int { return 5 }";
    return rb() ? "proc { 5 }" : lu() ? "function() return 5 end" : js() ? "() => 5" : "lambda: 5";
  }
  std::string def_twice() const {
    if (go()) return "func twice(n int) int { return n * 2 }";
    return rb() ? "def twice(n) n * 2 end"
           : lu() ? "function twice(n) return n * 2 end"
           : js() ? "function twice(n) { return n * 2 }" : "def twice(n):\n    return n * 2";
  }
  std::string sum_loop() const {  // twice_c(1) + ... + twice_c(4)
    if (go()) return "func() int { s := 0; for i := 1; i <= 4; i++ { s += twice_c(i) }; return s }()";
    return rb() ? "(1..4).map { |i| twice_c(i) }.sum"
                : lu() ? "local s = 0 for i = 1, 4 do s = s + twice_c(i) end return s"
                : js() ? "(() => { let s = 0; for (let i = 1; i <= 4; i++) s += twice_c(i); return s; })()"
                       : "sum(twice_c(i) for i in range(1, 5))";
  }
  std::string gc() const {  // js_gc is bound by register_all with the raw QuickJS API (JS_RunGC)
    if (go()) return "nfc.GC()";
    return rb() ? "GC.start" : lu() ? "collectgarbage(); collectgarbage()" : js() ? "js_gc()" : "import gc\ngc.collect()";
  }
  std::string spawn(int n) const {
    std::string c = std::to_string(n);
    if (go()) return "func() { for i := 0; i < " + c + "; i++ { NewVec3(1, 2, 3) } }()";
    return rb() ? c + ".times { Vec3.new(1, 2, 3) }"
                : lu() ? "for i = 1, " + c + " do Vec3.new(1, 2, 3) end"
                : js() ? "for (let i = 0; i < " + c + "; i++) { new Vec3(1, 2, 3); }"
                       : "for i in range(" + c + "):\n    Vec3(1, 2, 3)";
  }
  std::string keep(const std::string& n, const std::string& e) const {
    if (go()) return "var " + n + " = " + e;
    return gref(n) + " = " + e;
  }
  // A statement that raises a host error out of a loop with a cleanup that must run, and sets the global `flag` to 1.
  std::string ensure_flag() const {
    if (go()) return "func() { defer func() { flag = 1 }(); for i := 1; i <= 3; i++ { if i == 2 { fail7() } } }()";
    return rb() ? "begin; [1, 2, 3].each { |i| fail7 if i == 2 }; ensure; $flag = 1; end"
                : lu() ? "local ok, e = pcall(function() for i = 1, 3 do if i == 2 then fail7() end end end) flag = 1 error(e, 0)"
                : js() ? "try { for (const i of [1, 2, 3]) { if (i === 2) fail7(); } } finally { flag = 1; }"
                       : "try:\n    for i in [1, 2, 3]:\n        if i == 2:\n            fail7()\nfinally:\n    flag = 1";
  }
  std::string prelude() const {
    if (go())
      return "func errmsg(f func()) (out any) { defer func() { if r := recover(); r != nil { out = nfc.ErrMessage(r) } }(); f(); return nil }\n"
             "func errcls(f func()) (out any) { defer func() { if r := recover(); r != nil { out = nfc.ErrClass(r) } }(); f(); return nil }\n"
             "func raiser(m string) func() { return func() { panic(m) } }\n"
             "func raiser_host() func() { return func() { fail7() } }\n";
    if (rb())
      return "def errmsg; begin; yield; nil; rescue => e; e.message; end; end\n"
             "def errcls; begin; yield; nil; rescue => e; e.class.to_s; end; end\n"
             "def raiser(m) proc { raise m } end\n"
             "def raiser_host; proc { fail7 }; end\n"
             "class MyErr < StandardError; end\n";
    if (lu())
      return "function errmsg(f) local ok, e = pcall(f) if ok then return nil end if type(e) == 'table' then return e.message end "
             "return tostring(e) end\n"
             "function errcls(f) local ok, e = pcall(f) if ok then return nil end if type(e) == 'table' then return e.class end "
             "return 'LuaError' end\n"
             "function raiser(m) return function() error(m) end end\n"
             "function raiser_host() return function() fail7() end end\n";
    if (js())
      return "function errmsg(f) { try { f(); return null; } catch (e) { return (e instanceof Error) ? e.message : String(e); } }\n"
             "function errcls(f) { try { f(); return null; } catch (e) { return (e instanceof Error) ? e.constructor.name : typeof e; } }\n"
             "function raiser(m) { return () => { throw new Error(m); }; }\n"
             "function raiser_host() { return () => fail7(); }\n"
             "class MyErr extends Error {}\n";
    return "class MyErr(Exception):\n    pass\n"
           "def errmsg(f):\n    try:\n        f()\n    except Exception as e:\n        return str(e)\n"
           "def errcls(f):\n    try:\n        f()\n    except Exception as e:\n        return type(e).__name__\n"
           "def raiser(m):\n    def f():\n        raise ValueError(m)\n    return f\n"
           "def raiser_host():\n    return lambda: fail7()\n";
  }

  // A field of a registered class: obj.x, and in Go obj.X(); written obj.x = v, in Go obj.SetX(v).
  std::string fld(const std::string& obj, const std::string& f) const { return go() ? obj + "." + go_name(f) + "()" : obj + "." + f; }
  std::string setfld(const std::string& obj, const std::string& f, const std::string& v) const {
    return go() ? obj + ".Set" + go_name(f) + "(" + v + ")" : obj + "." + f + " = " + v;
  }
  // A global the script defines: x = v (Go needs a declaration).
  std::string assign(const std::string& n, const std::string& v) const { return go() ? "var " + n + " = " + v : n + " = " + v; }
  // A script value for the host to call a method on, and the call (Go strings have no methods: a *strings.Replacer does).
  std::string ab() const { return go() ? "strings.NewReplacer(\"a\", \"A\", \"b\", \"B\")" : "'ab'"; }
  Value upper_of(const Value& v) const { return go() ? v.call("Replace", std::string("ab")) : v.call(upper()); }

  // Go spellings: len2 -> Len2, to_s -> ToS; a list literal is typed by its first item.
  static std::string go_name(const std::string& s) {
    std::string out;
    bool up = true;
    for (char c : s) {
      if (c == '_') {
        up = true;
        continue;
      }
      out += up && c >= 'a' && c <= 'z' ? static_cast<char>(c - 'a' + 'A') : c;
      up = false;
    }
    return out;
  }
  static std::string go_list(const std::string& items) {
    const char* t = items.find('\'') != std::string::npos || items.find('"') != std::string::npos ? "string"
                    : items.find('.') != std::string::npos ? "float64" : "int";
    return std::string("[]") + t + "{" + items + "}";
  }
};

// ---- the host objects every language is given ----------------------------------------------------------------------
struct State {
  int counter = 5;
  std::string label = "a";
  const int limit = 10;
  Vec3 pos{1, 2, 3};
  Line line{{1, 1, 1}, {2, 2, 2}};
  Person bob{"bob", 30};
  int hits = 0;
  std::vector<int> big;
};

static void register_all(Context& ctx, State& st) {
  ctx.def_class<Vec3>("Vec3")
      .ctor<double, double, double>()
      .field("x", &Vec3::x)
      .field("y", &Vec3::y)
      .field("z", &Vec3::z)
      .method("len2", &Vec3::len2)
      .method("scale", &Vec3::scale)
      .method("dot", &Vec3::dot)
      .method("plus", &Vec3::plus)
      .method_fn("to_s", [](const Vec3& v) { return "(" + std::to_string(static_cast<int>(v.x)) + ")"; });
  ctx.def_class<Line>("Line").field("a", &Line::a).field("b", &Line::b);
  ctx.def_class<Person>("Person")
      .ctor<std::string, int>()
      .field("name", &Person::name)
      .field("age", &Person::age)
      .method("greet", &Person::greet);
  ctx.def_class<Unregistered>("Unreg");  // a class registered without a constructor
  ctx.bind("counter", st.counter).bind("label", st.label).bind("limit", st.limit);
  ctx.bind("pos", st.pos).bind("line", st.line).bind("bob", st.bob);
  ctx.set("answer", 42).set("greeting", std::string("hi")).set("pi", 3.25).set("origin", Vec3{0, 0, 0});
  ctx.bind_fn("twice_c", +[](int a) { return 2 * a; });
  ctx.bind_fn("scale_fn", &scale_fn);
  ctx.bind_fn("shout", &shout);
  ctx.bind_fn("total", &total);
  ctx.bind_fn("half", &half);
  ctx.bind_fn("length_of", &length_of);
  ctx.bind_fn("hit", [&st](int by) { st.hits += by; });  // a capturing lambda; a void result is nil
  ctx.bind_fn("big", [&st]() -> std::vector<int> { return st.big; });
  ctx.bind_fn("vadd", [](const Vec3& a, const Vec3& b) { return a.plus(b); });  // a result by value is a new object
  ctx.bind_fn("self_ref", [&st]() -> Vec3& { return st.pos; });                   // a reference result is shared
  ctx.bind_fn("is_null", [](const Vec3* p) { return p == nullptr; });
  ctx.bind_fn("make_nr", [] {
    struct NotRegistered {
      int v = 1;
    };
    return NotRegistered{};
  });
  ctx.bind_fn("thrower", []() -> int { throw std::runtime_error("host boom"); });
  ctx.bind_fn("fail7", []() -> int { throw HostFail("seven", 7); });
  ctx.bind_fn("throw_int", []() -> int { throw 42; });
  // A bound function that calls back into a script function, with an RAII object in its C++ frame.
  ctx.bind_fn("with_guard", [](Value f) -> int {
    Guard g;
    f.execute();
    return 1;
  });
#ifdef TEST_JS
  // JavaScript's gc() snippet: QuickJS frees by reference counting and collects cycles on JS_RunGC (raw access to the runtime).
  ctx.bind_fn("js_gc", [&ctx]() { JS_RunGC(JS_GetRuntime(nfcpoly::js_context(ctx))); });
#endif
}

// ---- the checks every language passes -----------------------------------------------------------------------------
static void shared_tests(const Lg& L) {
  g_lang = L.ln();
  const char* ln = L.ln();
  State st;
  st.big.resize(10000);
  for (int k = 0; k < 10000; ++k) st.big[k] = k;
  TCtx ctx;
  register_all(ctx, st);  // before the language starts: replayed into it
  ctx.eval_void(ln, L.prelude());

  std::printf("-- [%s] values, both ways\n", ln);
  CHECK(ctx.eval<int>(ln, "1 + 2") == 3);
  CHECK(ctx.eval<double>(ln, "1.5 * 4") == 6.0);
  CHECK(ctx.eval<double>(ln, "3") == 3.0);  // an integer is accepted where a floating type is asked
  CHECK(ctx.eval<int>(ln, "5.0") == 5);     // and a whole float where an integer is asked
  CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<int>(ln, "5.5"); }));
  CHECK(ctx.eval<std::string>(ln, L.str_rep()) == "ababab");
  CHECK(ctx.eval<std::string>(ln, L.nul_string()).size() == 3);  // strings are byte strings
  CHECK(ctx.eval<bool>(ln, "1 < 2") == true);
  CHECK(ctx.eval<bool>(ln, "1 > 2") == false);
  CHECK(ctx.eval<long long>(ln, L.pow40()) == (1LL << 40));
  CHECK(ctx.eval<std::uint8_t>(ln, "255") == 255);
  CHECK(ctx.eval_value(ln, L.nil()).is_nil());
  CHECK(!ctx.eval<std::optional<int>>(ln, L.nil()).has_value());
  CHECK(ctx.eval<std::optional<int>>(ln, "5").value() == 5);
  CHECK((ctx.eval<std::vector<int>>(ln, L.list("3, 1, 2")) == std::vector<int>{3, 1, 2}));
  CHECK((ctx.eval<std::vector<std::string>>(ln, L.list("'a', 'b', 'c'")) == std::vector<std::string>{"a", "b", "c"}));
  CHECK(ctx.eval<std::vector<double>>(ln, L.list("1, 2.5"))[1] == 2.5);
  ctx.eval<void>(ln, "1");
  ctx.eval_void(ln, "1");
  CHECK(ctx.eval_value(ln, "").is_nil());
  {
    std::vector<std::string> langs = Context::languages();
    CHECK(std::find(langs.begin(), langs.end(), L.name) != langs.end());
  }
  CHECK(throws<nfcpoly::UnsupportedLanguage>([&] { ctx.eval<int>("cobol", "1"); }));

  std::printf("-- [%s] state persists between evals\n", ln);
  ctx.eval_void(ln, L.assign("x", "41"));
  CHECK(ctx.eval<int>(ln, "x + 1") == 42);
  ctx.eval_void(ln, L.def_twice());
  CHECK(ctx.eval<int>(ln, "twice(x)") == 82);

  std::printf("-- [%s] Value\n", ln);
  {
    Value v = ctx.eval_value(ln, L.list("1, 2, 3"));
    CHECK(v.is_array() && !v.is_nil() && !v.is_int());
    CHECK(v.class_name() == L.array_class());
    CHECK(!v.inspect().empty());
    CHECK((v.as<std::vector<int>>() == std::vector<int>{1, 2, 3}));
    Value w = v;  // copies keep the array alive on their own
    v = Value();
    CHECK(w.is_array() && v.is_nil());
    Value m = std::move(w);
    CHECK(m.is_array());
    CHECK(L.upper_of(ctx.eval_value(ln, L.ab())).as<std::string>() == "AB");
    CHECK(throws<nfcpoly::Error>([] { Value().as<int>(); }));
    CHECK(throws<nfcpoly::ScriptError>([&] { m.call("no_such_method"); }));
  }

  std::printf("-- [%s] errors\n", ln);
  {
    bool got = false;
    try {
      ctx.eval<int>(ln, "1 +");
    } catch (const nfcpoly::SyntaxError& e) {
      got = std::string(e.what()).rfind("SyntaxError:", 0) == 0;
    }
    CHECK(got);
    CHECK(ctx.eval<int>(ln, "x + 1") == 42);  // the interpreter and its state survive a parse error
    auto script_error = [&](const std::string& code, const std::string& cls, const char* part) {
      try {
        ctx.eval<int>(ln, code);
      } catch (const nfcpoly::ScriptError& e) {
        return e.class_name() == cls && e.message().find(part) != std::string::npos &&
               std::string(e.what()).rfind(cls + ":", 0) == 0;
      }
      return false;
    };
    CHECK(script_error(L.raise_boom(), L.err_class(), "boom"));
    CHECK(script_error(L.zero_div(), L.zero_div_class(), ""));
    CHECK(script_error(L.nil_call(), L.nil_call_class(), ""));
    got = false;
    try {
      ctx.eval<int>(ln, L.raise_boom());
    } catch (const nfcpoly::ScriptError& e) {
      got = !e.backtrace().empty();
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>(ln, "'a'");
    } catch (const nfcpoly::ConversionError& e) {
      got = std::string(e.what()) == "expected integer, got string";
    }
    CHECK(got);
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::string>(ln, "1"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<bool>(ln, L.nil()); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::int8_t>(ln, "300"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::uint32_t>(ln, "-1"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<int>(ln, L.pow40()); }));
  }

  std::printf("-- [%s] bound functions\n", ln);
  CHECK(ctx.eval<int>(ln, "twice_c(21)") == 42);
  CHECK(ctx.eval<double>(ln, "scale_fn(1.5)") == 15.0);
  CHECK(ctx.eval<std::string>(ln, "shout('hey')") == "hey!");
  CHECK(ctx.eval<int>(ln, "total(" + L.list("1, 2, 3, 4") + ")") == 10);
  CHECK(ctx.eval<int>(ln, "half(10)") == 5);
  CHECK(ctx.eval_value(ln, "half(3)").is_nil());
  CHECK(ctx.eval<int>(ln, "length_of('hello')") == 5);
  CHECK(ctx.eval_value(ln, "hit(3)").is_nil() && st.hits == 3);
  CHECK(ctx.eval<int>(ln, L.sum_loop()) == 20);
  if (!L.go()) {  // Go checks the arity and the types of a call when it compiles it (go_tests)
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("twice_c(1, 2)")) == "wrong number of arguments (given 2, expected 1)");
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("twice_c('a')")) == "expected integer, got string");
  }
  CHECK(throws<nfcpoly::Error>([&] { ctx.bind_fn("Upper", +[] { return 1; }); }));
  CHECK(throws<nfcpoly::Error>([&] { ctx.bind_fn("a b", +[] { return 1; }); }));
  CHECK(ctx.eval<int>(ln, "total(" + L.fcall0("big") + ")") == 49995000);

  std::printf("-- [%s] bound variables\n", ln);
  CHECK(ctx.eval<int>(ln, "counter + 1") == 6);
  st.counter = 7;
  CHECK(ctx.eval<int>(ln, "counter") == 7);  // read live, not a copy taken at bind time
  ctx.eval_void(ln, L.setvar("counter", "100") + "; " + L.setvar("label", "'zed'"));
  CHECK(st.counter == 100 && st.label == "zed");
  CHECK(ctx.eval<int>(ln, "limit") == 10);
  CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval_void(ln, L.setvar("limit", "1")); }));  // read-only
  CHECK(ctx.eval<int>(ln, "answer") == 42);
  CHECK(ctx.eval<std::string>(ln, L.concat("greeting", "'!'")) == "hi!");
  CHECK(ctx.eval<double>(ln, "pi * 2") == 6.5);

  std::printf("-- [%s] registered classes\n", ln);
  CHECK(ctx.eval<double>(ln, L.fld("pos", "x") + " + " + L.fld("pos", "y") + " + " + L.fld("pos", "z")) == 6.0);
  ctx.eval_void(ln, L.setfld("pos", "x", "42"));
  CHECK(st.pos.x == 42);  // the script holds the host's object itself
  ctx.eval_void(ln, L.call1("pos", "scale", "2"));
  CHECK(st.pos.x == 84 && st.pos.y == 4 && st.pos.z == 6);
  CHECK(ctx.eval<double>(ln, L.call0("pos", "len2")) == 84.0 * 84 + 16 + 36);
  CHECK(ctx.eval<std::string>(ln, L.call0("pos", "to_s")) == "(84)");
  CHECK(ctx.eval<bool>(ln, "pos == pos"));
  CHECK(ctx.eval<double>(ln, L.call0(L.ctor("Vec3", "1, 2, 3"), "len2")) == 14.0);
  CHECK(ctx.eval<double>(ln, L.call1(L.ctor("Vec3", "1, 2, 3"), "dot", L.ctor("Vec3", "1, 1, 1"))) == 6.0);
  CHECK(ctx.eval<double>(ln, L.fld("vadd(" + L.ctor("Vec3", "1, 2, 3") + ", " + L.ctor("Vec3", "1, 1, 1") + ")", "x")) == 2.0);
  ctx.eval_void(ln, L.setfld(L.fcall0("self_ref"), "x", "5"));
  CHECK(st.pos.x == 5);
  CHECK(ctx.eval<bool>(ln, "is_null(" + L.nil() + ")") && !ctx.eval<bool>(ln, "is_null(pos)"));
  if (!L.go()) {  // (compile errors in Go)
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("vadd(1, 2)")) == "expected Vec3, got integer");
  CHECK(ctx.eval<std::string>(ln, L.guard_msg(L.call1(L.ctor("Person", "'a', 1"), "greet", "3"))) == "expected string, got integer");
  }
  {
    Vec3 copy = ctx.eval<Vec3>(ln, L.ctor("Vec3", "7, 8, 9"));  // by value: a copy of the script's object
    CHECK(copy.x == 7 && copy.z == 9);
    Value pv = ctx.eval_value(ln, "pos");
    CHECK(&pv.as<Vec3&>() == &st.pos && pv.as<Vec3*>() == &st.pos && pv.as<Vec3>().x == 5);
    CHECK(ctx.eval_value(ln, L.nil()).as<Vec3*>() == nullptr);
  }
  ctx.eval_void(ln, L.setfld(L.fld("line", "a"), "x", "9") + "; " + L.call1(L.fld("line", "b"), "scale", "2"));
  CHECK(st.line.a.x == 9 && st.line.b.x == 4);  // class-typed members are shared with their owner
  CHECK(ctx.eval<std::string>(ln, L.call1("bob", "greet", "'al'")) == "hello al, I am bob");
  ctx.eval_void(ln, L.setfld("bob", "name", "'rob'") + "; " + L.setfld("bob", "age", L.fld("bob", "age") + " + 1"));
  CHECK(st.bob.name == "rob" && st.bob.age == 31);
  CHECK(ctx.eval<std::string>(ln, L.fld(L.ctor("Person", "'eve', 5"), "name")) == "eve");
  CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval_void(ln, L.ctor("Unreg", "")); }));  // registered without a constructor
  ctx.eval_void(ln, L.setfld("origin", "x", "3"));  // a set() copy, owned by the script
  CHECK(ctx.eval<double>(ln, L.fld("origin", "x")) == 3.0);
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Vec3>("Again"); }));
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Unregistered>("Another"); }));
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Person>("lower"); }));
  CHECK(ctx.eval<std::string>(ln, L.guard_msg(L.fcall0("make_nr"))).find("def_class") != std::string::npos);

  std::printf("-- [%s] the script's GC releases script-owned objects\n", ln);
  {
    ctx.eval_void(ln, L.gc());
    int base = Vec3::live;
    ctx.eval_void(ln, L.spawn(2000));
    ctx.eval_void(ln, L.gc());
    CHECK(Vec3::live == base);
    Value keep = ctx.eval_value(ln, L.ctor("Vec3", "1, 2, 3"));  // a Value co-owns its object
    ctx.eval_void(ln, L.gc());
    ctx.eval_void(ln, L.gc());
    CHECK(Vec3::live == base + 1 && keep.as<Vec3&>().x == 1);
    keep = Value();
    ctx.eval_void(ln, L.gc());
    CHECK(Vec3::live == base);
    for (int k = 0; k < 3000; ++k) ctx.eval<int>(ln, "1 + 1");  // the interpreter's roots and arenas do not grow without bound
    Value arr = ctx.eval_value(ln, L.ab());
    for (int k = 0; k < 3000; ++k) L.upper_of(arr);
    CHECK(L.upper_of(arr).as<std::string>() == "AB");
  }
  {
    int before = Vec3::live;
    {
      Context c2;
      c2.def_class<Vec3>("Vec3").ctor<double, double, double>();
      c2.eval_void(ln, L.keep("keep", L.ctor("Vec3", "1, 2, 3")));
      CHECK(Vec3::live == before + 1);
    }
    CHECK(Vec3::live == before);  // closing the interpreter finalizes what the script still owned
  }

  std::printf("-- [%s] a Value outlives its context safely\n", ln);
  {
    Value arr, num, obj;
    {
      Context c3;
      c3.def_class<Vec3>("Vec3").ctor<double, double, double>();
      arr = c3.eval_value(ln, L.list("1, 2, 3"));
      num = c3.eval_value(ln, "42");
      obj = c3.eval_value(ln, L.ctor("Vec3", "1, 2, 3"));
    }
    CHECK(num.as<int>() == 42);     // plain values keep working
    CHECK(obj.as<Vec3&>().z == 3);  // and so does an object the Value co-owns
    CHECK(!arr.is_array());         // the interpreter is gone: nothing can be asked of it any more
    CHECK(throws<nfcpoly::Error>([&] { arr.call("size"); }));
    CHECK(throws<nfcpoly::Error>([&] { num.call(L.upper()); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { arr.as<std::vector<int>>(); }));
  }

  std::printf("-- [%s] C++ exceptions through scripts\n", ln);
  {
    // a script rescues a host exception as an NfcPoly HostError
    CHECK(ctx.eval<std::string>(ln, L.guard_cls(L.fcall0("thrower"))) == L.host_cls());
    CHECK(ctx.eval<std::string>(ln, L.guard_msg(L.fcall0("thrower"))) == "host boom");
    CHECK(ctx.eval<std::string>(ln, L.guard_msg(L.fcall0("throw_int"))) == "unknown C++ exception");
    // nothing rescued it: the host gets the original exception, type and payload intact
    bool got = false;
    try {
      ctx.eval<int>(ln, L.fcall0("fail7"));
    } catch (const HostFail& f) {
      got = f.code == 7 && std::string(f.what()) == "seven";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>(ln, L.fcall0("thrower"));
    } catch (const std::runtime_error& e) {
      got = std::string(e.what()) == "host boom";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>(ln, L.fcall0("throw_int"));
    } catch (int v) {
      got = v == 42;
    }
    CHECK(got);
    // through script frames in between, with cleanup code that must run
    ctx.eval_void(ln, L.keep("flag", "0"));
    got = false;
    try {
      ctx.eval<int>(ln, L.ensure_flag());
    } catch (const HostFail&) {
      got = true;
    }
    CHECK(got && ctx.eval<int>(ln, L.gref("flag")) == 1);
    CHECK(ctx.eval<int>(ln, "twice_c(4)") == 8);  // and the interpreter is still consistent

    // a bound function calls back into a script function (Value::execute) with an RAII object in its C++ frame
    int d0 = Guard::destroyed;
    CHECK(ctx.eval<int>(ln, "with_guard(" + L.noop() + ")") == 1 && Guard::alive == 0);  // the callback returns
    CHECK(ctx.eval<std::string>(ln, L.guard_msg("with_guard(raiser('inner'))")).find("inner") != std::string::npos);  // it raises, a script rescues
    CHECK(Guard::alive == 0);
    got = false;
    try {
      ctx.eval<int>(ln, "with_guard(raiser('deep'))");  // it raises and nothing rescues: ScriptError at the host
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == L.raiser_class() && e.message().find("deep") != std::string::npos;
    }
    CHECK(got && Guard::alive == 0);
    got = false;
    try {
      ctx.eval<int>(ln, "with_guard(" + L.fcall0("raiser_host") + ")");  // a host exception under the callback comes back as itself
    } catch (const HostFail& f) {
      got = f.code == 7;
    }
    CHECK(got && Guard::alive == 0 && Guard::destroyed == d0 + 4);

    // re-entrancy: a bound function that evaluates script code itself
    ctx.bind_fn("nested", [&ctx, ln]() { return ctx.eval<int>(ln, "40 + 2"); });
    CHECK(ctx.eval<int>(ln, L.fcall0("nested") + " + 1") == 43);
  }
}

// ---- Ruby only ----------------------------------------------------------------------------------------------------------
#ifdef TEST_RUBY
static void ruby_tests() {
  g_lang = "ruby (only)";
  std::printf("-- [ruby only] subclassing, raw mruby access, error identity\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Ruby, "ruby"};
  ctx.eval_void("ruby", L.prelude());
  // a script can subclass a bound class
  ctx.eval_void("ruby", "class P3 < Vec3; def norm1; x.abs + y.abs + z.abs; end; end");
  CHECK(ctx.eval<double>("ruby", "P3.new(1, -2, 3).norm1") == 6.0);
  // a HostError is a RuntimeError
  CHECK(ctx.eval<std::string>("ruby", "begin; thrower; rescue RuntimeError => e; 'rt'; end") == "rt");
  // Value::call on an array and with arguments
  Value v = ctx.eval_value("ruby", "[1, 2, 3]");
  CHECK(v.call("size").as<int>() == 3);
  CHECK(v.call("include?", 2).as<bool>());
  CHECK(v.call("join", "-").as<std::string>() == "1-2-3");
  CHECK(v.call("join", std::string("+")).as<std::string>() == "1+2+3");
  CHECK(ctx.eval_value("ruby", "'x'").call("*", 3).as<std::string>() == "xxx");

  // A script raise passes through a bound C++ function (raw mruby API: mruby's own throw) and releases its RAII objects.
  mrb_state* mrb = nfcpoly::mruby_state(ctx);
  ctx.bind_fn("with_guard_raw", [mrb](Value proc) -> int {
    Guard g;
    mrb_funcall(mrb, nfcpoly::mruby_raw(proc), "call", 0);
    return 1;
  });
  int d0 = Guard::destroyed;
  CHECK(ctx.eval<std::string>("ruby", "begin; with_guard_raw(proc { raise 'inner' }); rescue => e; e.message; end") == "inner");
  CHECK(Guard::alive == 0 && Guard::destroyed == d0 + 1);
  CHECK(ctx.eval<int>("ruby", "with_guard_raw(proc { 5 })") == 1 && Guard::alive == 0);
  // The script exception object that went through Value::execute and a bound function is raised again as itself.
  CHECK(ctx.eval<std::string>("ruby", "begin; with_guard(proc { raise MyErr, 'x' }); rescue MyErr => e; e.message; end") == "x");
}
#endif

// ---- Lua only -----------------------------------------------------------------------------------------------------------
#ifdef TEST_LUA
static void lua_tests() {
  g_lang = "lua (only)";
  std::printf("-- [lua only] raw Lua access, error identity, coroutines, the standard library\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Lua, "lua"};
  ctx.eval_void("lua", L.prelude());
  // The libraries a script gets: no files, no os.exit, no clock, no dofile.
  CHECK(ctx.eval<bool>("lua", "io == nil and os == nil and package == nil and dofile == nil and loadfile == nil"));
  CHECK(ctx.eval<std::string>("lua", "('abc'):upper() .. math.type(1) .. utf8.char(65)") == "ABCintegerA");
  // arrays are tables with keys 1..n only
  CHECK(ctx.eval_value("lua", "{1, 2, x = 3}").is_array() == false);
  CHECK(ctx.eval_value("lua", "{}").is_array());
  CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::vector<int>>("lua", "{1, 2, x = 3}"); }));
  // a class named like an internal metatable does not clash
  {
    Context c;
    c.def_class<Person>("Error").ctor<std::string, int>().field("name", &Person::name);
    CHECK(c.eval<std::string>("lua", "Error.new('x', 1).name") == "x");
    CHECK(c.eval<std::string>("lua", "local ok, e = pcall(error, 'plain') return tostring(e)").find("plain") != std::string::npos);
  }
  // an error value that is not a string or one of ours goes through a bound function as the same object
  CHECK(ctx.eval<bool>("lua", "local myobj = {k = 1}; local ok, e = pcall(with_guard, function() error(myobj) end); return e == myobj"));
  // a Lua error passes through a bound C++ function (raw API: Lua's own throw) and releases its RAII objects
  lua_State* L0 = nfcpoly::lua_state(ctx);
  (void)L0;
  ctx.bind_fn("with_guard_raw", [&ctx](Value f) -> int {
    Guard g;
    lua_State* S = nfcpoly::lua_state(ctx);
    nfcpoly::lua_push_value(S, f);
    lua_call(S, 0, 0);
    return 1;
  });
  int d0 = Guard::destroyed;
  CHECK(ctx.eval<bool>("lua", "local ok, e = pcall(with_guard_raw, raiser('inner')) return (not ok) and tostring(e):find('inner') ~= nil"));
  CHECK(Guard::alive == 0 && Guard::destroyed == d0 + 1);
  // coroutines: a bound function runs on the coroutine's thread, and a host exception crosses it
  CHECK(ctx.eval<int>("lua", "coroutine.wrap(function() return twice_c(21) end)()") == 42);
  CHECK(ctx.eval<std::string>("lua", "local co = coroutine.create(function() thrower() end) local ok, e = coroutine.resume(co) return e.message") == "host boom");
  CHECK(throws<HostFail>([&] { ctx.eval<int>("lua", "coroutine.wrap(function() fail7() end)()"); }));
  CHECK(ctx.eval<int>("lua", "twice_c(4)") == 8);
  // callbacks into Lua from inside a coroutine use that coroutine's thread
  ctx.bind_fn("run_cb", [](Value f) { return f.execute().as<int>(); });
  CHECK(ctx.eval<int>("lua", "coroutine.wrap(function() return run_cb(function() return 7 end) end)()") == 7);
  // multiple results: only the first is returned
  CHECK(ctx.eval<int>("lua", "return 1, 2, 3") == 1);
}
#endif

// ---- Python only ---------------------------------------------------------------------------------------------------------
#ifdef TEST_PYTHON
static void python_tests() {
  g_lang = "python (only)";
  std::printf("-- [python only] statements with a last expression, globals, bytes, big integers, error identity\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Python, "python"};
  ctx.eval_void("python", L.prelude());
  CHECK(ctx.eval<int>("python", "a = 3\nb = a * 2\nb + 1") == 7);  // the last expression statement is the value
  CHECK(ctx.eval_value("python", "a = 3").is_nil());               // a statement has none
  // bound variables are read live inside functions too
  ctx.eval_void("python", "def readc():\n    return counter");
  st.counter = 55;
  CHECK(ctx.eval<int>("python", "readc()") == 55);
  CHECK(ctx.eval<int>("python", "(1, 2, 3)[1]") == 2);
  CHECK((ctx.eval<std::vector<int>>("python", "(1, 2, 3)") == std::vector<int>{1, 2, 3}));  // a tuple is an array too
  CHECK(ctx.eval_value("python", "[1, 2, 2]").call("count", 2).as<int>() == 2);
  // text is UTF-8, other bytes become bytes objects
  CHECK(ctx.eval<std::string>("python", "'\\u00e9'") == "\xc3\xa9");
  ctx.bind_fn("blob", []() { return std::string("\xff\x01"); });
  CHECK(ctx.eval<bool>("python", "type(blob()).__name__ == 'bytes' and len(blob()) == 2"));
  CHECK(ctx.eval<std::string>("python", "b'ab'") == "ab");
  // an integer that does not fit stays in Python
  Value big = ctx.eval_value("python", "2**100");
  CHECK(!big.is_int() && big.class_name() == "int" && big.inspect() == "1267650600228229401496703205376");
  CHECK(throws<nfcpoly::ConversionError>([&] { big.as<long long>(); }));
  // the exception object that went through Value::execute and a bound function is raised again as itself
  CHECK(ctx.eval<bool>("python",
                       "obj = MyErr('x')\n"
                       "def boom():\n    raise obj\n"
                       "def same():\n    try:\n        with_guard(boom)\n    except MyErr as e:\n        return e is obj\n"
                       "same()"));
  CHECK(ctx.eval<std::string>("python", "type(pos).__name__ + ' ' + repr(pos)") == "Vec3 <Vec3 object>");
  // classes are real types: no constructor means a TypeError
  CHECK(ctx.eval<std::string>("python", L.guard_cls("Unreg()")) == "TypeError");
  CHECK(ctx.eval<std::string>("python", L.guard_cls("pos.nope")) == "AttributeError");
}
#endif

// ---- ast only (the nfcast engine) -------------------------------------------------------------------------------------------
#ifdef TEST_AST
static void ast_tests() {
  g_lang = "ast (only)";
  std::printf("-- [ast only] specialization, the collector, limits, the standard library, raw access\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Ast, "ast"};
  ctx.eval_void("ast", L.prelude());
  nfcast::State& S = nfcpoly::ast_state(ctx);
  // the nodes specialize on what they see, and a guard that fails falls back
  auto s0 = S.stats;
  CHECK(ctx.eval<int>("ast", "local s = 0 for i = 1, 1000 do s = s + i * 2 end return s") == 1001000);
  CHECK(S.stats.rewrites > s0.rewrites && S.stats.generic_ops == s0.generic_ops && S.stats.deopts == s0.deopts);
  ctx.eval_void("ast", "function addv(a, b) return a + b end");
  CHECK(ctx.eval<int>("ast", "addv(1, 2)") == 3);
  auto s1 = S.stats;
  CHECK(ctx.eval<double>("ast", "addv(1.5, 2)") == 3.5);  // a float reaches the integer node
  CHECK(S.stats.deopts == s1.deopts + 1);
  // the members of a host object are cached by its class: reading them again takes no slow path
  auto s2 = S.stats;
  CHECK(ctx.eval<double>("ast", "local t = 0 for i = 1, 200 do t = t + pos.x + pos.y end return t") == 200 * (1 + 2));
  CHECK(S.stats.generic_ops == s2.generic_ops);
  // the collector runs at every safe point and still frees what scripts own
  int base = Vec3::live;
  S.gc_stress = true;
  ctx.eval_void("ast", "for i = 1, 200 do local v = Vec3.new(i, 2, 3) local w = v:plus(v) w:scale(2) end");
  CHECK(ctx.eval<double>("ast", "local t = Vec3.new(1, 2, 3) local u = {t, Vec3.new(4, 5, 6)} return u[1].x + u[2]:len2()") == 1 + 77);
  S.gc_stress = false;
  ctx.eval_void("ast", L.gc());
  CHECK(Vec3::live == base);
  // a runaway recursion is a script error, not a crash
  CHECK(ctx.eval<bool>("ast", "local function f() return 1 + f() end local ok, e = pcall(f) return (not ok) and tostring(e):find('stack overflow') ~= nil"));
  bool got = false;
  try {
    ctx.eval<int>("ast", "local function f() return 1 + f() end return f()");
  } catch (const nfcpoly::ScriptError& e) {
    got = e.message().find("stack overflow") != std::string::npos;
  }
  CHECK(got);
  CHECK(ctx.eval<int>("ast", "twice_c(4)") == 8);  // and the interpreter is still consistent
  // the libraries a script gets: no files, no clock, no coroutines
  CHECK(ctx.eval<bool>("ast", "io == nil and os == nil and package == nil and dofile == nil and loadfile == nil and coroutine == nil and debug == nil"));
  CHECK(ctx.eval<std::string>("ast", "('abc'):upper() .. math.type(1) .. string.format('%03d', 7)") == "ABCinteger007");
  // arrays are tables with keys 1..n only
  CHECK(ctx.eval_value("ast", "{1, 2, x = 3}").is_array() == false);
  CHECK(ctx.eval_value("ast", "{}").is_array());
  CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::vector<int>>("ast", "{1, 2, x = 3}"); }));
  // an error value that is not a string or one of ours goes through a bound function as the same object
  CHECK(ctx.eval<bool>("ast", "local myobj = {k = 1}; local ok, e = pcall(with_guard, function() error(myobj) end); return e == myobj"));
  // a script error passes through a bound C++ function that uses the engine's own API (nfcast::Thrown is an ordinary C++
  // exception) and releases its RAII objects; the script that called the function rescues the very same error
  ctx.bind_fn("with_guard_raw", [&ctx](Value f) -> int {
    Guard g;
    nfcast::Rets out;
    nfcpoly::ast_state(ctx).call(nfcpoly::ast_value(f), nullptr, 0, out);
    return 1;
  });
  int d0 = Guard::destroyed;
  CHECK(ctx.eval<bool>("ast", "local ok, e = pcall(with_guard_raw, raiser('inner')) return (not ok) and tostring(e):find('inner') ~= nil"));
  CHECK(Guard::alive == 0 && Guard::destroyed == d0 + 1);
  CHECK(ctx.eval<bool>("ast", "local myobj = {k = 1}; local ok, e = pcall(with_guard_raw, function() error(myobj) end); return e == myobj"));
  // a host method is a value too: obj.method(obj, ...)
  CHECK(ctx.eval<double>("ast", "local f = pos.len2 return f(pos)") == st.pos.len2());
  CHECK(ctx.eval<std::string>("ast", L.guard_msg("pos:nope()")).find("attempt to call a nil value (method 'nope')") != std::string::npos);
  CHECK(ctx.eval<std::string>("ast", L.guard_msg("limit.x")).find("attempt to index a number value (global 'limit')") != std::string::npos);
  // load builds code at run time
  CHECK(ctx.eval<int>("ast", "load('return 6 * 7')()") == 42);
  CHECK(ctx.eval<bool>("ast", "local f, e = load('x ='); return f == nil and e:find('unexpected symbol') ~= nil"));
  // callbacks into script code from a bound function, with arguments
  ctx.bind_fn("call2", [](Value f, int a, int b) { return f.execute(a, b).as<int>(); });
  CHECK(ctx.eval<int>("ast", "call2(function(x, y) return x * 10 + y end, 4, 2)") == 42);
  // raw access: the engine's own State
  CHECK(S.globals->get_str(S.str("answer")).i == 42);
  CHECK(S.depth == 0 && S.top == S.stack && S.cur == nullptr);
}
#endif

// ---- JavaScript only ----------------------------------------------------------------------------------------------------
#ifdef TEST_JS
// A native function made with the raw QuickJS API: throws a TypeError itself.
static JSValue raw_throw(JSContext* c, JSValueConst, int, JSValueConst*) { return JS_ThrowTypeError(c, "%s", "from raw code"); }
// Calls its argument with the raw API with an RAII object in the C++ frame; a JavaScript exception is just the return value.
static JSValue raw_call(JSContext* c, JSValueConst, int argc, JSValueConst* argv) {
  Guard g;
  if (argc < 1) return JS_ThrowTypeError(c, "%s", "raw_call needs a function");
  return JS_Call(c, argv[0], JS_UNDEFINED, 0, nullptr);
}

struct Tag {  // a class with a read-only field
  const int id = 7;
  int n = 1;
};

struct Holder {  // a C++ object that keeps a script value: its destructor drops a handle while the context closes
  Value v;
  explicit Holder(Value x) : v(std::move(x)) {}
};

static void js_tests() {
  g_lang = "js (only)";
  std::printf("-- [js only] numbers, BigInt, objects, closures, promises, the standard library, raw QuickJS access\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Js, "js"};
  ctx.eval_void("js", L.prelude());
  auto num = [&](const char* code) { return ctx.eval_value("js", code); };

  // numbers: JavaScript has one type; a whole value within the safe integer range is an integer for the host
  CHECK(num("5.0").is_int() && num("5").is_int() && num("-7").is_int());
  CHECK(num("1.5").is_float() && num("0.1 + 0.2").is_float());
  CHECK(num("2 ** 40").is_int() && num("10 / 4 * 2").is_int() && num("Math.sqrt(16)").is_int() && num("0.5 + 0.5").is_int());  // computed as doubles
  CHECK(num("-(2 ** 53 - 1)").is_int() && num("-(2 ** 53)").is_float() && num("1e15").is_int());
  CHECK(num("2 ** 53 - 1").is_int());   // Number.MAX_SAFE_INTEGER
  CHECK(num("2 ** 53").is_float());     // beyond it a number is a float ...
  CHECK(ctx.eval<long long>("js", "2 ** 60") == (1LL << 60));  // ... which still converts to an integer type when whole
  CHECK(num("-0").is_float() && num("NaN").is_float() && num("Infinity").is_float() && num("1e21").is_float());
  CHECK(std::isnan(ctx.eval<double>("js", "NaN")) && ctx.eval<double>("js", "-Infinity") < 0);
  CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<int>("js", "Infinity"); }));
  CHECK(ctx.eval<double>("js", "0.1 + 0.2") == 0.1 + 0.2);
  CHECK(ctx.eval<double>("js", "1 / 3") == 1.0 / 3.0);
  // BigInt: an integer of 64 bits is an integer for the host, a larger one stays in JavaScript
  CHECK(num("5n").is_int() && ctx.eval<long long>("js", "2n ** 62n") == (1LL << 62));
  CHECK(ctx.eval<long long>("js", "-(2n ** 63n)") == std::numeric_limits<long long>::min());
  {
    Value huge = num("2n ** 70n");
    CHECK(!huge.is_int() && huge.class_name() == "bigint" && huge.inspect() == "1180591620717411303424");
    CHECK(throws<nfcpoly::ConversionError>([&] { huge.as<long long>(); }));
    CHECK(ctx.eval<bool>("js", "2n ** 63n > 9223372036854775807n"));
  }
  // and the other way: a C++ integer that is not a safe integer becomes a BigInt, so that it survives
  ctx.set("bigi", static_cast<long long>(1) << 60).set("safe", static_cast<long long>(1) << 40);
  ctx.set("lowest", std::numeric_limits<long long>::min()).set("nothing", std::optional<int>());
  CHECK(ctx.eval<std::string>("js", "typeof bigi + ',' + typeof safe") == "bigint,number");
  CHECK(ctx.eval<long long>("js", "bigi") == (static_cast<long long>(1) << 60) && ctx.eval<bool>("js", "bigi === 2n ** 60n"));
  CHECK(ctx.eval<long long>("js", "lowest") == std::numeric_limits<long long>::min());
  CHECK(ctx.eval<long long>("js", "safe") == (static_cast<long long>(1) << 40));
  CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval<int>("js", "bigi + 1"); }));  // JavaScript does not mix BigInt and Number

  // undefined and null are both nil for the host; the host's nil is null
  CHECK(num("undefined").is_nil() && num("null").is_nil() && num("void 0").is_nil());
  CHECK(ctx.eval<bool>("js", "nothing === null") && ctx.eval<bool>("js", "hit(0) === null"));
  CHECK(!ctx.eval<std::optional<int>>("js", "undefined").has_value());
  {
    std::vector<std::optional<int>> holes = ctx.eval<std::vector<std::optional<int>>>("js", "[1, , 3]");  // a hole reads undefined
    CHECK(holes.size() == 3 && holes[0] == 1 && !holes[1].has_value() && holes[2] == 3);
  }

  // objects and arrays
  {
    Value hostobj = num("pos");
    CHECK(hostobj.class_name() == "Vec3" && hostobj.inspect() == "<Vec3 object>" && &hostobj.as<Vec3&>() == &st.pos);
    CHECK(num("({get a() { throw new Error('x'); }})").inspect() == "[object Object]");  // inspect never throws
    CHECK(num("(() => 1)").inspect() == "() => 1" && num("'ab'").inspect() == "\"ab\"" && num("Symbol('s')").inspect() == "Symbol(s)");
    Value o = num("({a: 1, b: [1, 2], c: {d: 'x'}})");
    CHECK(!o.is_array() && o.class_name() == "Object" && o.inspect() == "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":\"x\"}}");
    CHECK(o.call("hasOwnProperty", "a").as<bool>() && !o.call("hasOwnProperty", "z").as<bool>());
    CHECK(throws<nfcpoly::ConversionError>([&] { o.as<std::vector<int>>(); }));
    Value nested = num("[[1, 2], [3]]");
    CHECK((nested.as<std::vector<std::vector<int>>>() == std::vector<std::vector<int>>{{1, 2}, {3}}));
    CHECK(!num("new Uint8Array(2)").is_array() && num("new Uint8Array(2)").class_name() == "Uint8Array");
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::vector<Value>>("js", "var cyc = []; cyc.push(cyc); cyc"); }));  // cyclic
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::vector<Value>>("js", "var sp = []; sp[20000000] = 1; sp"); }));  // too long to copy
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::string>("js", "new Uint8Array(2)"); }));  // bytes are not text
    Value sorted = num("[3, 1, 2]").call("sort");
    CHECK((sorted.as<std::vector<int>>() == std::vector<int>{1, 2, 3}) && sorted.call("join", "-").as<std::string>() == "1-2-3");
    Value m = num("new Map([[1, 'a'], [2, 'b']])");
    CHECK(m.class_name() == "Map" && m.call("get", 2).as<std::string>() == "b" && m.call("has", 3).as<bool>() == false);
  }

  // functions and closures
  {
    Value ctr = num("(() => { let n = 0; return () => ++n; })()");
    CHECK(ctr.execute().as<int>() == 1 && ctr.execute().as<int>() == 2 && ctr.execute().as<int>() == 3);
    Value add = num("(a, b) => a + b");
    CHECK(add.execute(2, 3).as<int>() == 5 && add.execute(std::string("a"), std::string("b")).as<std::string>() == "ab");
    Value getx = num("(v) => v.x * 2");
    Vec3 v{4, 0, 0};
    CHECK(getx.execute(v).as<int>() == 8);  // a host object goes in by reference
    Value obj = num("({k: 3, get() { return this.k; }})");
    CHECK(obj.call("get").as<int>() == 3);  // `this` is the receiver
    CHECK(throws<nfcpoly::ScriptError>([&] { obj.execute(); }));  // an object is not callable
    CHECK(num("(function () {})").class_name() == "Function" && num("(async () => 1)").class_name() == "AsyncFunction");
  }
  // state: function, var, let, const and class declarations persist between evals
  ctx.eval_void("js", "let lv = 5; const cv = 6; class K { get n() { return 7; } } var vv = 8; function ff() { return 9; }");
  CHECK(ctx.eval<int>("js", "lv + cv + new K().n + vv + ff()") == 35);
  CHECK(ctx.eval<bool>("js", "this === globalThis") && ctx.eval<int>("js", "'use strict'; 3") == 3);
  CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval_void("js", "'use strict'; undeclared_name = 1"); }));
  CHECK(ctx.eval<int>("js", "{ 1; 2 }") == 2 && num("var q1 = 1").is_nil() && ctx.eval<int>("js", "q1 = 4") == 4);  // completion values
  CHECK(ctx.eval<int>("js", "{a: 7}") == 7 && num("({a: 7})").class_name() == "Object");  // `{` starts a block: an object literal needs ()
  CHECK(ctx.eval<int>("javascript", "q1") == 4 && ctx.eval<int>("quickjs", "q1") == 4);  // the aliases name the same interpreter

  // bound classes are JavaScript classes
  CHECK(ctx.eval<bool>("js", "typeof Vec3 === 'function' && Vec3.name === 'Vec3' && typeof Vec3.prototype.len2 === 'function'"));
  CHECK(ctx.eval<std::string>("js", "String(new Vec3(1, 2, 3)) + ' ' + String(pos)") == "<Vec3 object> <Vec3 object>");
  CHECK(ctx.eval<std::string>("js", L.guard_cls("Vec3(1, 2, 3)")) == "TypeError");  // without new
  CHECK(ctx.eval<std::string>("js", L.guard_msg("Vec3(1, 2, 3)")).find("new") != std::string::npos);
  CHECK(ctx.eval<std::string>("js", L.guard_msg("new Vec3(1)")) == "wrong number of arguments (given 1, expected 3)");
  CHECK(ctx.eval<std::string>("js", L.guard_msg("new Vec3('a', 2, 3)")) == "expected number, got string");
  CHECK(ctx.eval<bool>("js", "new Vec3(1, 2, 3) instanceof Vec3 && !(({}) instanceof Vec3)"));
  CHECK(ctx.eval<int>("js", "Object.getOwnPropertyNames(new Vec3(1, 2, 3)).length") == 0);  // fields live on the prototype
  CHECK(ctx.eval<std::string>("js", "JSON.stringify(new Vec3(1, 2, 3)) + Object.keys(pos).length") == "{}0");
  CHECK(ctx.eval<std::string>("js", L.guard_cls("(() => { const f = pos.len2; return f(); })()")) == "TypeError");  // detached method
  CHECK(ctx.eval<double>("js", "(() => { const f = pos.len2; return f.call(new Vec3(1, 2, 3)); })()") == 14.0);
  ctx.eval_void("js", "class P3 extends Vec3 { norm1() { return Math.abs(this.x) + Math.abs(this.y) + Math.abs(this.z); } }");
  CHECK(ctx.eval<double>("js", "new P3(1, -2, 3).norm1()") == 6.0);  // a JavaScript class can extend a bound one
  CHECK(ctx.eval<bool>("js", "(() => { const p = new P3(1, 2, 3); return p instanceof Vec3 && p instanceof P3 && p.len2() === 14; })()"));
  CHECK(ctx.eval<double>("js", "vadd(new P3(1, 2, 3), new Vec3(1, 1, 1)).x") == 2.0);  // and is accepted where a Vec3 is
  {
    Tag tag;
    Context c;
    c.def_class<Tag>("Tag").field("id", &Tag::id).field("n", &Tag::n);
    c.bind("tag", tag);
    CHECK(c.eval<int>("js", "tag.id + tag.n") == 8);
    CHECK(c.eval<std::string>("js", "(() => { try { tag.id = 9; } catch (e) { return e.name + ': ' + e.message; } })()") ==
          "TypeError: field id of Tag is read-only");
    c.eval_void("js", "tag.n = 5");
    CHECK(tag.n == 5 && tag.id == 7);
  }
  // a bound variable is an accessor property of the global object
  CHECK(ctx.eval<bool>("js", "typeof Object.getOwnPropertyDescriptor(globalThis, 'counter').get === 'function'"));
  {
    Context c;
    int cnt = 5;
    c.bind("counter", cnt);
    c.eval_void("js", "let counter = 99");  // a global `let` shadows the bound variable, which stays reachable on globalThis
    CHECK(c.eval<int>("js", "counter") == 99 && c.eval<int>("js", "globalThis.counter") == 5);
    c.eval_void("js", "globalThis.counter = 6");
    CHECK(cnt == 6);
  }
  CHECK(ctx.eval<std::string>("js", L.guard_msg("limit = 3")) == "variable limit is read-only");

  // strings are UTF-8 on the host side
  CHECK(ctx.eval<std::string>("js", "'\\u00e9'") == "\xc3\xa9" && ctx.eval<std::string>("js", "String.fromCodePoint(0x1F600)") == "\xf0\x9f\x98\x80");
  CHECK(ctx.eval<std::string>("js", "shout('\xf0\x9f\x98\x80')") == "\xf0\x9f\x98\x80!");
  CHECK(ctx.eval<int>("js", "length_of('\xf0\x9f\x98\x80')") == 4 && ctx.eval<int>("js", "'\xf0\x9f\x98\x80'.length") == 2);  // bytes vs code units
  ctx.set("nulstr", std::string("a\0b", 3));
  CHECK(ctx.eval<int>("js", "nulstr.length") == 3 && ctx.eval<std::string>("js", "nulstr").size() == 3);
  ctx.bind_fn("blob", []() { return std::string("\xff\x01"); });  // not text: a Uint8Array
  CHECK(ctx.eval<bool>("js", "(() => { const b = blob(); return b instanceof Uint8Array && b.length === 2 && b[0] === 255; })()"));
  {  // a lone surrogate has no UTF-8 form: the string stays in JavaScript
    Value lone = num("'a\\ud800b'");
    CHECK(!lone.is_string() && lone.class_name() == "string" && lone.call("charCodeAt", 1).as<int>() == 0xd800);
    CHECK(throws<nfcpoly::ConversionError>([&] { lone.as<std::string>(); }));
    CHECK(ctx.eval<std::string>("js", "'\\ud83d\\ude00'") == "\xf0\x9f\x98\x80");  // a pair is a character
  }

  // exceptions: what JavaScript can throw
  {
    auto script_error = [&](const std::string& code, const std::string& cls, const std::string& msg) {
      try {
        ctx.eval_void("js", code);
      } catch (const nfcpoly::ScriptError& e) {
        return e.class_name() == cls && e.message() == msg;
      }
      return false;
    };
    CHECK(script_error("throw 'str'", "Error", "str") && script_error("throw 42", "Error", "42"));
    CHECK(script_error("throw {code: 3}", "Error", "[object Object]") && script_error("throw null", "Error", "null"));
    CHECK(script_error("throw {name: 'Odd', message: 'm'}", "Odd", "m"));  // an object that looks like an error is read as one
    CHECK(script_error("null.x", "TypeError", "cannot read property 'x' of null"));
    CHECK(script_error("undefined_name", "ReferenceError", "undefined_name is not defined"));
    CHECK(script_error("class VE extends Error {}; throw new VE('bad')", "VE", "bad"));  // a subclass that keeps the name
    CHECK(script_error("const e1 = new Error('x'); e1.name = 'Custom'; throw e1", "Custom", "x"));
    CHECK(script_error("throw new SyntaxError('rt')", "SyntaxError", "rt") && script_error("let lv = 2", "SyntaxError", "redeclaration of 'lv'"));
    CHECK(ctx.eval<std::string>("js", L.guard_msg("new Function('1 +')")).find("unexpected token") == 0);  // a runtime SyntaxError is a ScriptError
    CHECK(throws<nfcpoly::SyntaxError>([&] { ctx.eval_void("js", "1 +"); }) && !throws<nfcpoly::ScriptError>([&] { ctx.eval_void("js", "1"); }));
    bool got = false;
    try {
      ctx.eval_void("js", "(function f() {\n  throw new RangeError('deep');\n})()");
    } catch (const nfcpoly::ScriptError& e) {
      got = !e.backtrace().empty() && e.backtrace()[0].rfind("at f", 0) == 0 && e.backtrace()[0].find("snippet:2") != std::string::npos;
    }
    CHECK(got);
    // runaway recursion is an error, not a crash, and the interpreter survives it
    CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval_void("js", "(function r(n) { return r(n + 1) + 1; })(0)"); }));
    CHECK(ctx.eval<int>("js", "1 + 1") == 2);
  }
  // a HostError is a JavaScript Error that carries the C++ exception where JavaScript cannot see it
  CHECK(ctx.eval<bool>("js", "(() => { try { thrower(); } catch (e) { return e instanceof Error && e.name === 'NfcPoly::HostError' && "
                             "e.message === 'host boom' && typeof e.stack === 'string'; } })()"));
  CHECK(ctx.eval<bool>("js", "(() => { try { fail7(); } catch (e) { return Object.getOwnPropertySymbols(e).length === 0 && "
                             "JSON.stringify(e) === '{}' && !Object.getOwnPropertyNames(e).some((n) => /host|nfcpoly/i.test(n)); } })()"));
  // the very value that went through Value::execute and a bound function is thrown again, whatever it is
  CHECK(ctx.eval<bool>("js", "var tobj = new MyErr('x'); function boom() { throw tobj; }\n"
                             "(() => { try { with_guard(boom); } catch (e) { return e === tobj; } })()"));
  CHECK(ctx.eval<bool>("js", "var plain = {tag: 1}; (() => { try { with_guard(() => { throw plain; }); } catch (e) { return e === plain; } })()"));
  CHECK(ctx.eval<std::string>("js", L.guard_msg("with_guard(() => { throw 'prim'; })")) == "prim");

  // re-entrancy: eval inside a bound function inside eval, nested
  ctx.bind_fn("down", [&ctx](int n) -> int { return n == 0 ? 0 : 1 + ctx.eval<int>("js", "down(" + std::to_string(n - 1) + ")"); });
  CHECK(ctx.eval<int>("js", "down(40)") == 40);

  // promises: the jobs they queue run when the outermost call into JavaScript ends
  ctx.eval_void("js", "var order = []; Promise.resolve().then(() => order.push('then')); order.push('sync');");
  CHECK(ctx.eval<std::string>("js", "order.join(',')") == "sync,then");
  ctx.eval_void("js", "var res = 0; (async () => { res = (await Promise.resolve(40)) + 2; })()");
  CHECK(ctx.eval<int>("js", "res") == 42);
  ctx.bind_fn("later", [](Value f) { return f.execute().as<int>(); });  // a job is not run inside a nested call ...
  ctx.bind_fn("later_eval", [&ctx]() { return ctx.eval<int>("js", "1"); });  // ... or a nested eval
  CHECK(ctx.eval<std::string>("js", "(() => { const log = []; Promise.resolve().then(() => log.push('job')); "
                                    "log.push(String(later(() => 1))); log.push(String(later_eval())); return log.join(','); })()") == "1,1");
  ctx.eval_void("js", "var joblog = []; Promise.resolve().then(() => joblog.push('job')); later(() => 1); joblog.push('after');");
  CHECK(ctx.eval<std::string>("js", "joblog.join(',')") == "after,job");  // it ran when the outermost eval ended
  {  // a job that throws is an error of the eval that ran it: the first one, after every job has run
    bool got = false;
    try {
      ctx.eval_void("js", "queueMicrotask(() => { throw new RangeError('first'); }); queueMicrotask(() => { throw new TypeError('second'); }); "
                          "queueMicrotask(() => { globalThis.third = 1; });");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "RangeError" && e.message() == "first";
    }
    CHECK(got && ctx.eval<int>("js", "third") == 1 && ctx.eval<int>("js", "1 + 1") == 2);
  }
  {
    JSContext* c = nfcpoly::js_context(ctx);
    Value p = num("Promise.resolve(7)");
    CHECK(p.class_name() == "Promise");
    JSValue jp = nfcpoly::js_value(p);
    CHECK(JS_PromiseState(c, jp) == JS_PROMISE_FULFILLED);
    JSValue r = JS_PromiseResult(c, jp);
    CHECK(JS_IsNumber(r) && JS_VALUE_GET_INT(r) == 7);
    JS_FreeValue(c, r);
    JS_FreeValue(c, jp);
    Value times6 = num("(x) => x * 6");
    Value q = p.call("then", times6);  // the callback has run when the call returns
    JSValue jq = nfcpoly::js_value(q);
    JSValue qr = JS_PromiseResult(c, jq);
    CHECK(JS_PromiseState(c, jq) == JS_PROMISE_FULFILLED && JS_VALUE_GET_INT(qr) == 42);
    JS_FreeValue(c, qr);
    JS_FreeValue(c, jq);
    Value rej = num("Promise.reject(new TypeError('no'))");
    rej.call("catch", num("(e) => 0"));
    JSValue jr = nfcpoly::js_value(rej);
    CHECK(JS_PromiseState(c, jr) == JS_PROMISE_REJECTED);
    JS_FreeValue(c, jr);
  }

  // the standard library, compiled by the backend under test
  CHECK(ctx.eval<std::string>("js", "JSON.stringify({a: [1, 2, {b: 3}], s: 'q\"'})") == "{\"a\":[1,2,{\"b\":3}],\"s\":\"q\\\"\"}");
  CHECK(ctx.eval<std::string>("js", "'2024-05-06'.replace(/(\\d+)-(\\d+)-(\\d+)/, '$3.$2.$1')") == "06.05.2024");
  CHECK(ctx.eval<std::string>("js", "/(?<y>\\d{4})-(?<m>\\d\\d)/u.exec('on 1999-12-31').groups.y") == "1999");
  CHECK(ctx.eval<std::string>("js", "new Date(86400000).toISOString()") == "1970-01-02T00:00:00.000Z");
  CHECK(ctx.eval<long long>("js", "Date.UTC(2000, 0, 1)") == 946684800000LL);
  CHECK(ctx.eval<std::string>("js", "[(1 / 3).toString(), (123.456).toFixed(1), (1e21).toString(), (255).toString(16), "
                                    "Number.MIN_VALUE.toString(), (0.000001234).toExponential(2)].join(' ')") ==
        "0.3333333333333333 123.5 1e+21 ff 5e-324 1.23e-6");
  CHECK(ctx.eval<double>("js", "Number.parseFloat('1.7976931348623157e308')") == std::numeric_limits<double>::max());
  CHECK(ctx.eval<double>("js", "Math.hypot(3, 4)") == 5.0 && ctx.eval<double>("js", "Math.pow(2, 0.5)") == std::pow(2.0, 0.5));
  CHECK(ctx.eval<std::string>("js", "['\\u00e9'.normalize('NFD').length, '\\u01c6'.toUpperCase().codePointAt(0), 'stra\\u00dfe'.toUpperCase()].join()") ==
        "2,452,STRASSE");
  CHECK(ctx.eval<std::string>("js", "(() => { function* g() { yield 1; yield* [2, 3]; } const [a, ...rest] = g(); "
                                    "const m = new Map([['k', new Set([1, 2])]]); const {x = 10, ...o} = {y: 1, z: 2}; "
                                    "return `${a} ${rest} ${m.get('k').size} ${x} ${Object.keys(o)}`; })()") == "1 2,3 2 10 y,z");
  CHECK(ctx.eval<std::string>("js", "(() => { class A { #p = 1; static s = 2; get p() { return this.#p; } } "
                                    "const px = new Proxy({}, {get: (t, k) => 'p' + String(k)}); const w = new WeakRef(px); "
                                    "return [new A().p, A.s, px.q, typeof w.deref(), Symbol('s').toString()].join(); })()") == "1,2,pq,object,Symbol(s)");
  // Atomics, all element sizes (the backend maps them to the libatomic functions on the qbe back end)
  {
    std::string one = "2,3,2,1,2,3,2,1";
    std::string expect;
    for (int k = 0; k < 8; ++k) expect += (k ? "," : "") + one;
    CHECK(ctx.eval<std::string>("js",
                                "(() => { const out = []; for (const T of [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, "
                                "Uint32Array, BigInt64Array, BigUint64Array]) { const big = T === BigInt64Array || T === BigUint64Array; "
                                "const c = (n) => big ? BigInt(n) : n; const a = new T(new SharedArrayBuffer(T.BYTES_PER_ELEMENT * 2)); "
                                "Atomics.store(a, 0, c(2)); out.push(Number(Atomics.add(a, 0, c(1))), Number(Atomics.sub(a, 0, c(1))), "
                                "Number(Atomics.exchange(a, 0, c(1))), Number(Atomics.compareExchange(a, 0, c(1), c(2))), "
                                "Number(Atomics.or(a, 0, c(1))), Number(Atomics.and(a, 0, c(2))), Number(Atomics.xor(a, 0, c(3))), "
                                "Number(Atomics.load(a, 0))); } return out.join(','); })()") == expect);
    // Atomics.wait would block the host thread for good: it is refused
    CHECK(ctx.eval<std::string>("js", L.guard_cls("Atomics.wait(new Int32Array(new SharedArrayBuffer(8)), 0, 0)")) == "TypeError");
  }
  // what a script does not get: no files, no timers, no console, no module system
  CHECK(ctx.eval<bool>("js", "[typeof require, typeof process, typeof console, typeof setTimeout, typeof std, typeof os, typeof print, "
                             "typeof fetch].every((t) => t === 'undefined')"));
  CHECK(throws<nfcpoly::SyntaxError>([&] { ctx.eval_void("js", "import x from 'y'"); }));  // no modules
  CHECK(throws<nfcpoly::SyntaxError>([&] { ctx.eval_void("js", "await Promise.resolve(1)"); }));  // no top-level await

  // script-owned C++ objects: a cycle in JavaScript is released by JS_RunGC, and closing the context releases the rest
  {
    ctx.eval_void("js", L.gc());
    int base = Vec3::live;
    ctx.eval_void("js", "(() => { const a = new Vec3(1, 2, 3); a.me = a; })()");
    CHECK(Vec3::live == base + 1);  // reference counting alone cannot free a cycle
    ctx.eval_void("js", L.gc());
    CHECK(Vec3::live == base);
    for (int k = 0; k < 20; ++k) {
      Value fn, keep;  // handles that outlive the context
      {
        Context c;
        c.def_class<Vec3>("Vec3").ctor<double, double, double>();
        c.eval_void("js", "var a = {}; a.self = a; a.v = new Vec3(1, 2, 3); var f = () => a; f.v = new Vec3(4, 5, 6); a.f = f;");
        fn = c.eval_value("js", "(() => a)");
        keep = c.eval_value("js", "new Vec3(7, 8, 9)");
        CHECK(Vec3::live == base + 3);
      }
      CHECK(Vec3::live == base + 1);  // closing the context released the cycle; the Value still co-owns its object
      CHECK(keep.as<Vec3&>().x == 7 && !fn.is_array() && throws<nfcpoly::Error>([&] { fn.execute(); }));
    }
    CHECK(Vec3::live == base);
    // closing a context drops handles that other handles' objects own (a Holder's Value is a handle too)
    for (int k = 0; k < 5; ++k) {
      Value arr, fn;
      {
        Context c;
        c.def_class<Holder>("Holder").ctor<Value>();
        arr = c.eval_value("js", "var f = () => 1; [new Holder(f), new Holder(() => 2)]");
        fn = c.eval_value("js", "f");
      }
      CHECK(!arr.is_array() && !fn.is_int());
    }
  }

  // raw QuickJS access
  {
    JSContext* c = nfcpoly::js_context(ctx);
    JSValue gl = JS_GetGlobalObject(c);
    JS_SetPropertyStr(c, gl, "raw_throw", JS_NewCFunction(c, raw_throw, "raw_throw", 0));
    JS_SetPropertyStr(c, gl, "raw_call", JS_NewCFunction(c, raw_call, "raw_call", 1));
    JS_FreeValue(c, gl);
    CHECK(ctx.eval<std::string>("js", L.guard_cls("raw_throw()")) == "TypeError" && ctx.eval<std::string>("js", L.guard_msg("raw_throw()")) == "from raw code");
    bool got = false;
    try {
      ctx.eval_void("js", "raw_throw()");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "TypeError";
    }
    CHECK(got);
    int d0 = Guard::destroyed;
    CHECK(ctx.eval<std::string>("js", L.guard_msg("raw_call(raiser('inner'))")) == "inner" && Guard::alive == 0);
    CHECK(ctx.eval<int>("js", "raw_call(() => 5)") == 5 && Guard::destroyed == d0 + 2);
    CHECK(ctx.eval<bool>("js", "(() => { try { raw_call(raiser_host()); } catch (e) { return e instanceof Error; } })()"));  // a host error through raw code
    CHECK(throws<HostFail>([&] { ctx.eval<int>("js", "raw_call(raiser_host())"); }) && Guard::alive == 0);
    Value arr = num("[1, 2, 3]");
    JSValue ja = nfcpoly::js_value(arr);
    int64_t len = 0;
    CHECK(JS_IsArray(ja) && JS_GetLength(c, ja, &len) == 0 && len == 3);
    JS_FreeValue(c, ja);
    JSValue plain = nfcpoly::js_value(num("41 + 1"));  // a plain value is converted
    CHECK(JS_IsNumber(plain) && JS_VALUE_GET_INT(plain) == 42);
    JSValue made = JS_NewObject(c);
    JS_SetPropertyStr(c, made, "k", JS_NewInt32(c, 5));
    Value w = nfcpoly::js_wrap(ctx, made);  // the reference is duplicated
    JS_FreeValue(c, made);
    CHECK(w.inspect() == "{\"k\":5}" && w.call("hasOwnProperty", "k").as<bool>());
    CHECK(throws<nfcpoly::Error>([&] { nfcpoly::js_value(Value()); }));
    CHECK(throws<nfcpoly::Error>([&] { nfcpoly::js_value(Value(nfcpoly::detail::Var::integer(1))); }));
  }
}
#endif

#ifdef TEST_GO
struct Late {  // registered after a function that mentions it (go_tests)
  int v;
  explicit Late(int x) : v(x) {}
};
#endif

// ---- Go only ------------------------------------------------------------------------------------------------------------
#ifdef TEST_GO
static void go_tests() {
  g_lang = "go (only)";
  std::printf("-- [go only] typed bindings, what is live, goroutines, generics, errors, the standard library whitelist\n");
  State st;
  Context ctx;
  register_all(ctx, st);
  const Lg L{Go, "go"};
  ctx.eval_void("go", L.prelude());
  auto str = [&](const std::string& code) { return ctx.eval<std::string>("go", code); };
  auto num = [&](const std::string& code) { return ctx.eval<int>("go", code); };
  auto yes = [&](const std::string& code) { return ctx.eval<bool>("go", code); };
  auto msg_of = [&](const std::string& expr) { return ctx.eval<std::string>("go", L.guard_msg(expr)); };
  auto compile_error = [&](const std::string& code) {  // the SyntaxError text, empty when the code compiled
    try {
      ctx.eval_void("go", code);
    } catch (const nfcpoly::SyntaxError& e) {
      return std::string(e.what());
    }
    return std::string();
  };
  auto script_error = [&](const std::string& code) {  // "class|message" of the ScriptError, "none" when there was none
    try {
      ctx.eval_void("go", code);
    } catch (const nfcpoly::ScriptError& e) {
      return e.class_name() + "|" + e.message();
    }
    return std::string("none");
  };

  // ---- the host's types become Go types
  ctx.bind_fn("peek", [&st]() { return st.counter; });
  ctx.bind_fn("bump", [&st]() { st.counter += 1; });
  ctx.bind_fn("vsum", [](const std::vector<Vec3>& vs) { double s = 0; for (const Vec3& v : vs) s += v.x; return s; });
  ctx.bind_fn("vmake", [] { return std::vector<Vec3>{Vec3(1, 2, 3), Vec3(4, 5, 6)}; });
  ctx.bind_fn("opt_vec", [](int k) -> std::optional<Vec3> { if (k) return Vec3(k, 0, 0); return std::nullopt; });
  ctx.bind_fn("take_ptr", [](const Vec3* p) { return p ? p->x : -1.0; });
  ctx.bind_fn("words", [] { return std::vector<std::string>{"a", "b"}; });
  ctx.bind_fn("echo", [](Value v) { return v; });
  ctx.bind_fn("negate", [](bool b) { return !b; });
  ctx.bind_fn("plus1", [](std::size_t n) { return n + 1; });
  ctx.bind_fn("half_f", [](float f) { return f / 2; });
  ctx.bind_fn("join2", [](const std::vector<std::string>& v, std::string_view sep) {
    std::string out;
    for (std::size_t k = 0; k < v.size(); ++k) out += (k ? std::string(sep) : std::string()) + v[k];
    return out;
  });
  CHECK(str("fmt.Sprintf(\"%T\", twice_c)") == "func(int) int");
  CHECK(str("fmt.Sprintf(\"%T\", half)") == "func(int) *int");
  CHECK(str("fmt.Sprintf(\"%T\", plus1)") == "func(uint) uint");
  CHECK(str("fmt.Sprintf(\"%T\", join2)") == "func([]string, string) string");
  CHECK(num("*half(10)") == 5 && yes("half(3) == nil"));
  CHECK(ctx.eval<std::size_t>("go", "plus1(4)") == 5);
  CHECK(yes("negate(false)") && ctx.eval<double>("go", "half_f(5)") == 2.5);
  CHECK(str("join2([]string{\"x\", \"y\", \"z\"}, \"-\")") == "x-y-z");
  CHECK((ctx.eval<std::vector<std::string>>("go", "words()") == std::vector<std::string>{"a", "b"}));
  CHECK(ctx.eval<double>("go", "vsum([]*Vec3{NewVec3(1, 2, 3), NewVec3(4, 5, 6)})") == 5.0);  // vector<Vec3> is []*Vec3
  CHECK(ctx.eval<double>("go", "vsum(vmake())") == 5.0 && num("len(vmake())") == 2);
  CHECK(ctx.eval<double>("go", "vmake()[1].Z()") == 6.0);
  CHECK(ctx.eval<double>("go", "opt_vec(7).X()") == 7.0 && yes("opt_vec(0) == nil"));  // optional<Vec3> is *Vec3, nil for none
  CHECK(ctx.eval<double>("go", "take_ptr(nil)") == -1.0 && ctx.eval<double>("go", "take_ptr(NewVec3(9, 0, 0))") == 9.0);
  CHECK(str("echo(\"s\").(string)") == "s" && num("echo(5).(int)") == 5);                        // a Value is an any
  CHECK(ctx.eval<double>("go", "echo(pos).(*Vec3).Len2()") == st.pos.len2());                     // a host object comes back as a wrapper
  ctx.eval_void("go", "echo(pos).(*Vec3).SetX(77)");
  CHECK(st.pos.x == 77);                                                                          // of the same C++ object
  CHECK(yes("pos == pos") && yes("self_ref() != self_ref()"));                                    // a new wrapper per T& result
  ctx.eval_void("go", "self_ref().SetX(3)");
  CHECK(st.pos.x == 3);
  // a call is checked when it compiles
  CHECK(compile_error("twice_c(1, 2)").find("too many arguments") != std::string::npos);
  CHECK(!compile_error("twice_c(\"a\")").empty());
  CHECK(compile_error("NewVec3(1, 2)").find("not enough arguments") != std::string::npos);
  CHECK(!compile_error("vadd(1, 2)").empty());
  CHECK(!compile_error("var s string = twice_c(1)").empty());
  // what the host cannot convert is a TypeError panic that a script can recover
  CHECK(msg_of("twice_c(1 << 40)").find("out of range") != std::string::npos);
  CHECK(msg_of("vadd(nil, nil)") == "expected Vec3, got nil");
  CHECK(ctx.eval<std::string>("go", L.guard_cls("vadd(nil, nil)")) == "TypeError");
  // Value::call on a Go function: the arguments are converted to the parameter types
  {
    Value f = ctx.eval_value("go", "func(a int, b string, c []float64, d bool) string { return fmt.Sprint(a, b, c, d) }");
    CHECK(f.class_name() == "func(int, string, []float64, bool) string");
    CHECK(f.execute(1, std::string("x"), std::vector<double>{1.5, 2}, true).as<std::string>() == "1x[1.5 2] true");
    CHECK(throws<nfcpoly::ScriptError>([&] { f.execute(1, 2, std::vector<double>{}, true); }));  // an int for a string
    CHECK(throws<nfcpoly::ScriptError>([&] { f.execute(1); }));                                  // arity
    Value g = ctx.eval_value("go", "func(v *Vec3, n int8) float64 { return v.X() * float64(n) }");
    CHECK(g.execute(&st.pos, 2).as<double>() == 2 * st.pos.x);
    CHECK(throws<nfcpoly::ScriptError>([&] { g.execute(&st.pos, 300); }));  // out of range for int8
    Value h = ctx.eval_value("go", "func() (int, error) { return 0, errors.New(\"no luck\") }");
    bool got = false;
    try {
      h.execute();
    } catch (const nfcpoly::ScriptError& e) {
      got = e.message() == "no luck" && e.class_name() == "errors.errorString";  // a trailing error result is a script error
    }
    CHECK(got);
    CHECK(ctx.eval_value("go", "strconv.Atoi").execute(std::string("12")).as<int>() == 12);  // several results: the first
    // a method of a compiled type
    Value sb = ctx.eval_value("go", "&strings.Builder{}");
    sb.call("WriteString", std::string("ab"));
    sb.call("WriteString", std::string("cd"));
    CHECK(sb.call("String").as<std::string>() == "abcd" && sb.call("Len").as<int>() == 4);
    CHECK(throws<nfcpoly::ScriptError>([&] { sb.call("NoSuchMethod"); }));
    // and a method of a host object, by its Go name
    Value pv = ctx.eval_value("go", "pos");
    CHECK(pv.call("Len2").as<double>() == st.pos.len2());
    pv.call("SetX", 11.0);
    CHECK(st.pos.x == 11 && pv.call("X").as<double>() == 11);
    CHECK(throws<nfcpoly::ScriptError>([&] { pv.call("Nope"); }));
    // the methods of a type the script defines cannot be reached by reflection (yaegi): Value::call says so
    ctx.eval_void("go", "type Acc struct{ n int }\nfunc (a *Acc) Add(k int) { a.n += k }\nfunc NewAcc() *Acc { return &Acc{} }");
    Value acc = ctx.eval_value("go", "NewAcc()");
    CHECK(throws<nfcpoly::ScriptError>([&] { acc.call("Add", 1); }));
    ctx.eval_void("go", "var theacc = NewAcc()\ntheacc.Add(2)");
    CHECK(num("theacc.n") == 2);
  }

  // ---- what is live: bound variables are Go variables synchronized at the boundaries
  std::printf("-- [go only] bound variables\n");
  st.counter = 5;
  CHECK(num("counter") == 5);
  CHECK(num("counter = 41; peek()") == 41);       // a host function sees the script's write
  CHECK(num("bump(); counter") == 42);            // and the script sees the host function's
  CHECK(st.counter == 42);
  ctx.eval_void("go", "func rd() int { return counter }");
  st.counter = 55;
  CHECK(num("rd()") == 55);                       // the host's value at the start of the evaluation
  Value rd = ctx.eval_value("go", "rd");
  st.counter = 60;
  CHECK(rd.execute().as<int>() == 60);            // and at the start of Value::call
  ctx.eval_void("go", "func wr() { counter = 70 }");
  ctx.eval_value("go", "wr").execute();
  CHECK(st.counter == 70);                        // written back when the call ends
  ctx.eval_void("go", "counter++");
  CHECK(st.counter == 71);
  ctx.eval_void("go", "label += \"!\"");
  CHECK(st.label == "a!");
  {
    bool got = false;
    try {
      ctx.eval_void("go", "limit = 3");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "ReadOnlyError" && std::string(e.what()).find("limit") != std::string::npos;
    }
    CHECK(got && num("limit") == 10);             // the write is noticed at the end of the evaluation and undone
    CHECK(msg_of("func() int { limit = 4; peek(); return 0 }()").find("read-only") != std::string::npos);  // or at the next host call
    CHECK(num("limit") == 10);
  }

  // ---- goroutines run on threads of their own: they cannot call the host
  std::printf("-- [go only] goroutines\n");
  ctx.eval_void("go", R"go(
func sumPar() int {
	var wg sync.WaitGroup
	var mu sync.Mutex
	n := 0
	for i := 1; i <= 8; i++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			mu.Lock()
			n += k
			mu.Unlock()
		}(i)
	}
	wg.Wait()
	return n
}
func hostFromGoroutine() string {
	ch := make(chan string)
	go func() {
		defer func() { ch <- nfc.ErrClass(recover()) }()
		hit(1)
		ch <- "no error"
	}()
	s := <-ch
	return s
}
func hostMessageFromGoroutine() string {
	ch := make(chan string)
	go func() {
		defer func() { ch <- nfc.ErrMessage(recover()) }()
		twice_c(5)
		ch <- "no error"
	}()
	s := <-ch
	return s
}
)go");
  CHECK(num("sumPar()") == 36);
  CHECK(ctx.eval<int>("golang", "6 * 7") == 42);  // the alias
  st.hits = 0;
  CHECK(str("hostFromGoroutine()") == "GoroutineError" && st.hits == 0);  // refused before any host code ran
  CHECK(str("hostMessageFromGoroutine()").find("goroutine") != std::string::npos);
  // a goroutine that outlives the evaluation is refused too
  ctx.eval_void("go", "var late = make(chan string, 1)\ngo func() { time.Sleep(20 * time.Millisecond); defer func() { late <- nfc.ErrClass(recover()) }(); hit(1) }()");
  usleep(120 * 1000);
  CHECK(str("<-late") == "GoroutineError" && st.hits == 0);
  CHECK(num("twice_c(4)") == 8);  // the interpreter is unharmed
  CHECK(num("time.Sleep(time.Millisecond); 3") == 3);

  // ---- generics, closures, maps, structs, interfaces, errors
  std::printf("-- [go only] the language: generics, closures, maps, structs, interfaces, errors\n");
  ctx.eval_void("go", R"go(
func MapSl[T, U any](xs []T, f func(T) U) []U {
	var r []U
	for _, x := range xs {
		r = append(r, f(x))
	}
	return r
}
type Number interface{ ~int | ~float64 }
func SumOf[T Number](xs []T) T {
	var s T
	for _, x := range xs {
		s += x
	}
	return s
}
type Stack[T any] struct{ items []T }
func (s *Stack[T]) Push(x T) { s.items = append(s.items, x) }
func (s *Stack[T]) Len() int { return len(s.items) }
func counter3() func() int {
	n := 0
	return func() int { n++; return n }
}
type Shape interface{ Area() float64 }
type Sq struct{ s float64 }
type Circ struct{ r float64 }
func (q Sq) Area() float64 { return q.s * q.s }
func (c Circ) Area() float64 { return 3 * c.r * c.r }
func kind(s Shape) string {
	switch v := s.(type) {
	case Circ:
		return fmt.Sprint("circ", v.r)
	case Sq:
		return fmt.Sprint("sq", v.s)
	}
	return "?"
}
type Base struct{ Name string }
func (b Base) Hello() string { return "hi " + b.Name }
type Derived struct {
	Base
	Age int
}
var ErrNeg = errors.New("negative")
func check(x int) (int, error) {
	if x < 0 {
		return 0, fmt.Errorf("check %d: %w", x, ErrNeg)
	}
	return x, nil
}
func atoiFails() bool {
	n, err := strconv.Atoi("x")
	return err != nil && n == 0
}
func deferOrder() (out string) {
	defer func() { out += "a" }()
	defer func() { out += "b" }()
	out = "c"
	return
}
func recovered() (n int) {
	defer func() { recover(); n = 7 }()
	var a []int
	i := 3
	_ = a[i]
	return 1
}
func labels() int {
	total := 0
outer:
	for i := 0; i < 5; i++ {
		for j := 0; j < 5; j++ {
			if j == 3 {
				continue outer
			}
			if i == 3 {
				break outer
			}
			total++
		}
	}
	return total
}
)go");
  CHECK(str("strings.Join(MapSl[int, string]([]int{1, 2, 3}, func(i int) string { return strconv.Itoa(i * i) }), \",\")") == "1,4,9");
  CHECK(num("SumOf([]int{1, 2, 3})") == 6 && ctx.eval<double>("go", "SumOf([]float64{1.5, 2.5})") == 4.0);
  CHECK(num("s := &Stack[string]{}; s.Push(\"a\"); s.Push(\"b\"); s.Len()") == 2);
  // yaegi v0.16.1 cannot infer the type arguments of a call when they differ (a gap, not a design choice)
  CHECK(!compile_error("MapSl([]int{1}, func(i int) string { return \"\" })").empty());
  CHECK(num("c := counter3(); c(); c(); c()") == 3);
  CHECK(num("m := map[string][]int{}; m[\"a\"] = append(m[\"a\"], 1, 2); m[\"b\"] = nil; len(m) + len(m[\"a\"])") == 4);
  CHECK(str("fmt.Sprint(map[string]int{\"b\": 2, \"a\": 1})") == "map[a:1 b:2]");
  CHECK(ctx.eval<double>("go", "shapes := []Shape{Sq{2}, Circ{1}}; t := 0.0; for _, sh := range shapes { t += sh.Area() }; t") == 7.0);
  CHECK(str("kind(Sq{2}) + kind(Circ{1})") == "sq2circ1");
  CHECK(str("Derived{Base{\"x\"}, 3}.Hello()") == "hi x");
  CHECK(yes("_, e := check(-1); errors.Is(e, ErrNeg)"));
  CHECK(str("_, e2 := check(-2); e2.Error()") == "check -2: negative");
  CHECK(num("v, _ := check(4); v") == 4);
  CHECK(yes("atoiFails()"));
  CHECK(str("deferOrder()") == "cba" && num("recovered()") == 7 && num("labels()") == 9);
  CHECK(str("var sb strings.Builder; for i := 0; i < 3; i++ { fmt.Fprintf(&sb, \"%d;\", i) }; sb.String()") == "0;1;2;");
  CHECK(num("xs := []int{5, 2, 9}; sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] }); xs[0]*100 + xs[2]") == 209);
  CHECK(str("regexp.MustCompile(`a+b`).FindString(\"xaaab\")") == "aaab");
  CHECK(num("len(strings.Fields(\" a b  c \"))") == 3 && str("strings.ToUpper(\"é\")") == "\xc3\x89");
  CHECK(str("string([]rune(\"héllo\")[1])") == "\xc3\xa9");
  CHECK(str("b, _ := json.Marshal(map[string]int{\"a\": 1}); string(b)") == "{\"a\":1}");
  CHECK(num("sel := make(chan int, 1); sel <- 4; v := 0; select { case x := <-sel: v = x; default: v = -1 }; v") == 4);

  // ---- panics: the class and message the host sees
  std::printf("-- [go only] panics and errors\n");
  CHECK(script_error("panic(\"plain\")") == "panic|plain");
  CHECK(script_error("panic(42)") == "panic|42");
  CHECK(script_error("panic(errors.New(\"custom\"))") == "errors.errorString|custom");
  CHECK(script_error("panic(fmt.Errorf(\"w: %w\", errors.New(\"inner\")))") == "fmt.wrapError|w: inner");
  CHECK(script_error("var m map[string]int; m[\"a\"] = 1").rfind("runtime.Error|", 0) == 0);
  CHECK(script_error("a := 0; _ = 1 / a").rfind("runtime.Error|", 0) == 0);
  // a script-defined error type: yaegi keeps only the data of the value that was panicked with, so the host sees a panic
  ctx.eval_void("go", "type MyErr struct{ Code int }\nfunc (e *MyErr) Error() string { return \"myerr\" }");
  CHECK(script_error("panic(&MyErr{3})") == "panic|&{3}");
  // recover() after a panic of the script gives a reflect.Value in yaegi: nfc.Unwrap gives the value back
  CHECK(str("func() (s string) { defer func() { s, _ = nfc.Unwrap(recover()).(string) }(); panic(\"text\") }()") == "text");
  CHECK(str("func() (s string) { defer func() { e, _ := nfc.Unwrap(recover()).(error); s = e.Error() }(); panic(errors.New(\"an error\")) }()") == "an error");
  CHECK(str("errmsg(func() { panic(\"direct\") })") == "direct" && str("errcls(func() { panic(\"direct\") })") == "panic" &&
        str("errcls(func() { panic(errors.New(\"e\")) })") == "errors.errorString");  // classified in the script, as the host does
  // a host error recovered in the script is a typed value
  CHECK(str("func() (s string) { defer func() { r := recover(); if he, ok := r.(*nfc.HostError); ok { s = \"host:\" + he.Msg } }(); thrower(); return \"none\" }()") == "host:host boom");
  CHECK(str("func() (s string) { defer func() { r := recover(); if e, ok := r.(*nfc.Error); ok { s = e.Class } }(); twice_c(1 << 40); return \"none\" }()") == "TypeError");
  // identity: a script error that passes through a bound function (Value::execute) is raised again as the same value
  ctx.eval_void("go", "var sentinel = errors.New(\"sentinel\")\nfunc same() (res bool) { defer func() { res = nfc.Unwrap(recover()) == any(sentinel) }(); with_guard(func() { panic(sentinel) }); return false }");
  CHECK(yes("same()"));
  CHECK(msg_of("with_guard(func() { with_guard(func() { panic(\"deep\") }) })") == "deep");  // through two frames of host code
  CHECK(Guard::alive == 0);

  // ---- the evaluation of a source text
  std::printf("-- [go only] evaluating sources\n");
  CHECK(num("func sq(a int) int { return a * a }; sq(9)") == 81);                  // declarations and an expression
  CHECK(num("// only a comment\nx1 := 3 // another\nx1 * 2") == 6);
  CHECK(ctx.eval_value("go", "// nothing but a comment").is_nil());
  CHECK(ctx.eval_value("go", "x2 := 9").is_nil() && num("x2") == 9);               // a statement has no value
  CHECK(ctx.eval_value("go", "hit(0)").is_nil() && ctx.eval_value("go", "x2 = 10").is_nil());
  CHECK(num("strconv.Atoi(\"7\")") == 7);                                           // the first of several values
  CHECK(num("func() int {\n\treturn 3\n}()") == 3);
  CHECK(ctx.eval<std::string>("go", "`raw\nstring`") == "raw\nstring");
  CHECK(compile_error("func main() {}").find("main") != std::string::npos);        // would run again after every evaluation
  CHECK(compile_error("package main\nfunc pk() {}").find("package clause") != std::string::npos);
  // a statement that starts with func runs once (yaegi would define a main and run it again after each later evaluation)
  ctx.eval_void("go", "var runs = 0");
  ctx.eval_void("go", "func() { runs++ }()");
  ctx.eval_void("go", "func() { runs++ }()");
  CHECK(num("runs") == 2 && num("runs") == 2);
  ctx.eval_void("go", "func() { defer func() { runs += 10 }() }()");
  CHECK(num("runs") == 12 && num("1") == 1 && num("runs") == 12);
  // redefining a function: later calls see the new definition
  ctx.eval_void("go", "func redef() int { return 1 }");
  ctx.eval_void("go", "func redef() int { return 2 }");
  CHECK(num("redef()") == 2);
  // an error leaves the interpreter usable
  CHECK(!compile_error("undefined_name + 1").empty() && num("redef()") == 2);
  CHECK(!compile_error("x3 := ").empty() && num("redef()") == 2);
  CHECK(script_error("panic(\"again\")") == "panic|again" && num("redef()") == 2);

  // ---- gaps of yaegi v0.16.1 that docs/notes/poly.md names: these pin the behavior that was observed
  std::printf("-- [go only] yaegi's gaps\n");
  CHECK(script_error("func rch() int { c := make(chan int, 1); c <- 5; return <-c }; rch()").find("unaddressable") != std::string::npos);  // return <-ch
  CHECK(!compile_error("for i := range 3 { _ = i }").empty());                                                                         // range over an integer
  CHECK(str("func dargs() (out string) { for i := 0; i < 3; i++ { defer func(k int) { out += strconv.Itoa(k) }(i) }; return }; dargs()") == "333");  // deferred arguments alias the variables
  CHECK(script_error("var np *Vec3; _ = np.X()").rfind("reflect.ValueError|", 0) == 0);                                             // a method on a nil pointer is not a runtime.Error
  CHECK(script_error("var anyv any = 1; _ = anyv.(string)").rfind("interp.cfgError|", 0) == 0);                                       // nor a failed type assertion
  CHECK(script_error("ia := []int{1}; ix := 5; _ = ia[ix]") == "panic|reflect: slice index out of range");                          // nor an index out of range

  // ---- the standard library is a whitelist
  std::printf("-- [go only] the standard library whitelist\n");
  CHECK(str("strings.ToTitle(\"x\") + strconv.Quote(\"y\") + fmt.Sprint(math.Floor(2.5), unicode.IsUpper('A'), utf8.RuneLen('é'))") == "X\"y\"2 true 2");
  CHECK(yes("rand.New(rand.NewSource(1)).Intn(10) < 10"));
  CHECK(num("bits.OnesCount(255)") == 8 && num("len(hex.EncodeToString([]byte{1, 2}))") == 4);
  CHECK(num("var once sync.Once; n := 0; once.Do(func() { n++ }); once.Do(func() { n++ }); n") == 1);
  CHECK(num("var ai atomic.Int64; ai.Add(5); int(ai.Load())") == 5);
  CHECK(num("l := list.New(); l.PushBack(1); l.PushBack(2); l.Len()") == 2);
  CHECK(str("ctx2, cancel := context.WithCancel(context.Background()); cancel(); fmt.Sprint(ctx2.Err())") == "context canceled");
  CHECK(num("r := bufio.NewScanner(strings.NewReader(\"a\\nb\\nc\")); n := 0; for r.Scan() { n++ }; n") == 3);
  for (const char* pkg : {"os", "os/exec", "net", "net/http", "unsafe", "reflect", "syscall", "runtime", "plugin", "io/ioutil",
                          "path/filepath", "os/signal", "debug/elf"}) {
    CHECK(compile_error(std::string("import \"") + pkg + "\"").find("not available") != std::string::npos);  // the message names the whitelist
  }
  CHECK(!compile_error("os.Getenv(\"HOME\")").empty() && !compile_error("exec.Command(\"ls\")").empty());
  CHECK(str("_, serr := fmt.Scan(&x2); serr.Error()") == "EOF");  // yaegi points fmt.Scan at the interpreter's own, empty, input
  CHECK(yes("slices.Contains([]string{\"a\", \"b\"}, \"b\")") && num("cmp.Compare(1, 2)") == -1 && num("slices.Index([]int{5, 6, 7}, 7)") == 2);
  CHECK(!compile_error("slices.Sort([]int{2, 1})").empty());    // yaegi's generic sources of slices and maps are partial
  CHECK(!compile_error("time.LoadLocation(\"UTC\")").empty());  // reads files: not exported
  CHECK(num("import \"strings\"\nlen(strings.Repeat(\"a\", 3))") == 3);              // an import that is already in force is accepted
  CHECK(num("import str2 \"strings\"\nlen(str2.Repeat(\"a\", 4))") == 4);            // and an alias for one
  CHECK(compile_error("import (\n\t\"strings\"\n\t\"os\"\n)").find("os") != std::string::npos);

  // ---- declarations: the order they are made in, values of every shape, other threads
  std::printf("-- [go only] declarations\n");
  {
    Context c;  // a function bound before the class it mentions: defined with the class
    c.bind_fn("early", [](const Late& l) { return l.v; });
    c.def_class<Late>("Late").ctor<int>().field("v", &Late::v);
    CHECK(c.eval<int>("go", "early(NewLate(4))") == 4);
    CHECK(throws<nfcpoly::SyntaxError>([&] { c.eval<int>("go", "early(5)"); }));  // typed: it takes a *Late
    c.set("nums", std::vector<int>{1, 2, 3}).set("fl", std::vector<double>{1.5, 2}).set("strs", std::vector<std::string>{"a", "b"});
    c.set("objs", std::vector<Late>{Late(7), Late(8)}).set("nothing", std::optional<int>()).set("flag", true).set("big", 1LL << 40);
    c.set("mixed", std::vector<double>{});
    {
      std::string types = c.eval<std::string>("go", "fmt.Sprintf(\"%T %T %T %T %T %T\", nums, fl, strs, objs, nothing, flag)");
      CHECK(types.rfind("[]int []float64 []string []*", 0) == 0 && types.find(" <nil> bool") == types.size() - 11);
    }
    CHECK(c.eval<int>("go", "nums[2] + objs[1].V() + len(strs)") == 3 + 8 + 2);
    CHECK(c.eval<bool>("go", "nothing == nil && flag") && c.eval<long long>("go", "big") == (1LL << 40));
    CHECK(c.eval<int>("go", "len(mixed)") == 0);
    Context d;  // a function bound after the interpreter started, before its class is registered: the class is an any there
    CHECK(d.eval<int>("go", "1") == 1);
    d.bind_fn("early2", [](const Late& l) { return l.v; });
    d.def_class<Late>("Late").ctor<int>().field("v", &Late::v);
    CHECK(d.eval<int>("go", "early2(NewLate(5))") == 5);
    CHECK(d.eval<std::string>("go", "fmt.Sprintf(\"%T\", early2)") == "func(interface {}) int");  // not a *Late: unknown then
    d.bind_fn("later", [](const Late& l) { return Late(l.v + 1); });  // the class is known now: typed
    CHECK(d.eval<int>("go", "later(NewLate(5)).V()") == 6);
  }
  {
    Context c;  // two interpreters in a process are separate worlds
    Context d;
    c.eval_void("go", "var shared = 1");
    d.eval_void("go", "var shared = 10");
    c.eval_void("go", "shared++");
    CHECK(c.eval<int>("go", "shared") == 2 && d.eval<int>("go", "shared") == 10);
    d.eval_void("go", "shared--");
    CHECK(c.eval<int>("go", "shared") == 2 && d.eval<int>("go", "shared") == 9);
  }
  {
    Context c;  // a context used from another thread, one at a time
    int a = c.eval<int>("go", "40 + 2");
    int b = 0;
    std::thread t([&] { b = c.eval<int>("go", "b0 := 5; b0 * 2"); });
    t.join();
    CHECK(a == 42 && b == 10 && c.eval<int>("go", "b0 + 1") == 6);
  }

  // ---- host objects and the collector
  std::printf("-- [go only] host objects and the collector\n");
  {
    go_collect(ctx);
    int base = Vec3::live;
    ctx.eval_void("go", "var held *Vec3\nvar heldSlice []*Vec3");
    ctx.eval_void("go", "held = NewVec3(1, 2, 3)");
    ctx.eval_void("go", "heldSlice = []*Vec3{NewVec3(4, 5, 6), vmake()[0]}");
    CHECK(Vec3::live > base);
    go_collect(ctx);            // vmake() made two objects, one of which the script kept
    int with = Vec3::live;
    CHECK(with == base + 3);
    go_collect(ctx);
    CHECK(Vec3::live == with);  // still referenced from the script's variables
    ctx.eval_void("go", "held = nil");
    ctx.eval_void("go", "heldSlice = nil");
    go_collect(ctx);
    CHECK(Vec3::live == base);  // dropped by the script: released by the next collection
    ctx.eval_void("go", "func() { m := map[int]*Vec3{}; for i := 0; i < 100; i++ { m[i] = NewVec3(1, 1, 1) } }()");
    go_collect(ctx);
    CHECK(Vec3::live == base);
    // an object that the host also holds stays alive
    Value hv = ctx.eval_value("go", "NewVec3(8, 8, 8)");
    go_collect(ctx);
    CHECK(Vec3::live == base + 1 && hv.as<Vec3&>().x == 8);
    hv = Value();
    go_collect(ctx);
    CHECK(Vec3::live == base);
    // a host object that crossed as a Value argument and a result
    ctx.eval_void("go", "func() { for i := 0; i < 200; i++ { echo(NewVec3(1, 2, 3)) } }()");
    go_collect(ctx);
    CHECK(Vec3::live == base);
  }
  {
    // A closed Context is collected even though its script held host objects (a Go interpreter is about 1 MB, so sixty that
    // were kept alive show in the size of the process; the pages go back to the system at the collection).
    auto rss_kb = [] {
      std::ifstream f("/proc/self/statm");
      long total = 0, resident = 0;
      f >> total >> resident;
      return resident * (sysconf(_SC_PAGESIZE) / 1024);
    };
    auto cycle = [](int n) {
      for (int i = 0; i < n; ++i) {
        Context c;
        c.def_class<Late>("Late").ctor<int>().field("v", &Late::v);
        c.eval_void("go", "keep := NewLate(1); keep.SetV(2)");
      }
    };
    cycle(10);
    go_collect(ctx);
    long before = rss_kb();
    if (before > 0) {
      cycle(60);
      go_collect(ctx);
      CHECK(rss_kb() - before < 30 * 1024);
    }
  }
}
#endif

// ---- several languages in one Context -----------------------------------------------------------------------------------
static void cross_tests(const std::vector<Lg>& ls) {
  g_lang = "cross";
  std::printf("-- [cross] one context, %zu languages\n", ls.size());
  State st;
  TCtx ctx;
  register_all(ctx, st);
  for (const Lg& L : ls) ctx.eval_void(L.ln(), L.prelude());
  // declarations made after the languages started reach every one of them
  ctx.bind_fn("late", +[](int a) { return a + 1000; });
  ctx.set("late_const", 7);
  for (const Lg& L : ls) {
    g_lang = L.ln();
    CHECK(ctx.eval<int>(L.ln(), "late(1)") == 1001);
    CHECK(ctx.eval<int>(L.ln(), "late_const") == 7);
  }
  g_lang = "cross";
  // one host object, every language mutating it
  double x0 = st.pos.x;
  for (const Lg& L : ls) ctx.eval_void(L.ln(), L.setfld("pos", "x", L.fld("pos", "x") + " + 1"));
  CHECK(st.pos.x == x0 + static_cast<double>(ls.size()));
  // an array crosses by copy, into every language
  Value arr = ctx.eval_value(ls[0].ln(), ls[0].list("1, 2, 3"));
  ctx.set("shared", arr);
  for (const Lg& L : ls) {
    g_lang = L.ln();
    CHECK(ctx.eval<int>(L.ln(), "total(shared)") == 6);
  }
  g_lang = "cross";
  // an object crosses by reference: every language holds the very same C++ object
  Value obj = ctx.eval_value(ls[0].ln(), ls[0].ctor("Vec3", "1, 2, 3"));
  ctx.set("shared_obj", obj);
  ctx.eval_void(ls.back().ln(), ls.back().setfld("shared_obj", "x", "99"));
  CHECK(obj.as<Vec3&>().x == 99);
  for (const Lg& L : ls) {
    g_lang = L.ln();
    CHECK(ctx.eval<double>(L.ln(), L.fld("shared_obj", "x")) == 99.0);
  }
  g_lang = "cross";
  // a value that is not plain data stays in its own language
  if (ls.size() > 1) {
    const Lg& A = ls[0];
    const Lg& B = ls[1];
    Value fn = ctx.eval_value(A.ln(), A.noop());
    ctx.set("only_here", fn);
    CHECK(ctx.eval<int>(A.ln(), A.rb() ? "only_here.call" : "only_here()") == 5);
    bool hidden = false;  // an undefined name is an error in Ruby and Python, nil in Lua, a compile error in Go
    try {
      hidden = ctx.eval_value(B.ln(), "only_here").is_nil();
    } catch (const nfcpoly::ScriptError&) {
      hidden = true;
    } catch (const nfcpoly::SyntaxError&) {
      hidden = true;
    }
    CHECK(hidden);
    // and cannot be passed as an argument into another language
    Value lst = ctx.eval_value(B.ln(), B.list(""));
    if (B.rb() || B.py() || B.js()) {
      CHECK(throws<nfcpoly::ConversionError>([&] { lst.call(B.py() ? "append" : "push", fn); }));
      // an array can: Value::call converts it by copy
      Value nums = ctx.eval_value(A.ln(), A.list("4, 5"));
      if (B.js()) {  // concat returns a new array
        CHECK((lst.call("concat", nums).as<std::vector<int>>() == std::vector<int>{4, 5}));
      } else {
        lst.call(B.py() ? "extend" : "concat", nums);
        CHECK((lst.as<std::vector<int>>() == std::vector<int>{4, 5}));
      }
    }
  }
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::vector<Lg> langs;
#ifdef TEST_RUBY
  langs.push_back(Lg{Ruby, "ruby"});
#endif
#ifdef TEST_LUA
  langs.push_back(Lg{Lua, "lua"});
#endif
#ifdef TEST_PYTHON
  langs.push_back(Lg{Python, "python"});
#endif
#ifdef TEST_AST
  langs.push_back(Lg{Ast, "ast"});
#endif
#ifdef TEST_JS
  langs.push_back(Lg{Js, "js"});
#endif
#ifdef TEST_GO
  langs.push_back(Lg{Go, "go"});
#endif
  try {
    for (const Lg& L : langs) shared_tests(L);
#ifdef TEST_RUBY
    ruby_tests();
#endif
#ifdef TEST_LUA
    lua_tests();
#endif
#ifdef TEST_PYTHON
    python_tests();
#endif
#ifdef TEST_AST
    ast_tests();
#endif
#ifdef TEST_JS
    js_tests();
#endif
#ifdef TEST_GO
    go_tests();
#endif
    if (langs.size() > 1) cross_tests(langs);
  } catch (const std::exception& e) {
    std::printf("uncaught exception: %s\n", e.what());
    return 2;
  }
  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
