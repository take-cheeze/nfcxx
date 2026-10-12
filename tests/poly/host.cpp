// nfcpoly host test: exit status 0 when every check passes. Run by tests/poly/run.sh, which builds it with nfcxx together
// with lib/poly/nfcpoly.cpp and the language backends it defines TEST_RUBY / TEST_LUA / TEST_PYTHON / TEST_JS for.
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

// ---- one language's way of writing things -----------------------------------------------------------------------
enum Kind { Ruby, Lua, Python, Ast, Js };  // Ast: Lua syntax, run by the nfcast engine
struct Lg {
  Kind k;
  std::string name;
  bool rb() const { return k == Ruby; }
  bool lu() const { return k == Lua || k == Ast; }  // Lua syntax
  bool py() const { return k == Python; }
  bool js() const { return k == Js; }
  const char* ln() const { return name.c_str(); }

  std::string nil() const { return py() ? "None" : js() ? "null" : "nil"; }
  std::string list(const std::string& items) const { return lu() ? "{" + items + "}" : "[" + items + "]"; }
  std::string ctor(const std::string& cls, const std::string& args) const {
    return py() ? cls + "(" + args + ")" : js() ? "new " + cls + "(" + args + ")" : cls + ".new(" + args + ")";
  }
  std::string call0(const std::string& obj, const std::string& m) const {
    return rb() ? obj + "." + m : lu() ? obj + ":" + m + "()" : obj + "." + m + "()";
  }
  std::string call1(const std::string& obj, const std::string& m, const std::string& a) const {
    return lu() ? obj + ":" + m + "(" + a + ")" : obj + "." + m + "(" + a + ")";
  }
  std::string fcall0(const std::string& f) const { return rb() ? f : f + "()"; }
  std::string setvar(const std::string& n, const std::string& v) const { return rb() ? "self." + n + " = " + v : n + " = " + v; }
  std::string concat(const std::string& a, const std::string& b) const { return lu() ? a + " .. " + b : a + " + " + b; }
  std::string gref(const std::string& n) const { return rb() ? "$" + n : n; }  // a script global
  // The error message / class name of EXPR, or nil when it raises nothing. EXPR must be an expression.
  std::string guard_msg(const std::string& e) const {
    return rb() ? "errmsg { " + e + " }" : lu() ? "errmsg(function() return " + e + " end)"
           : js() ? "errmsg(() => " + e + ")" : "errmsg(lambda: " + e + ")";
  }
  std::string guard_cls(const std::string& e) const {
    return rb() ? "errcls { " + e + " }" : lu() ? "errcls(function() return " + e + " end)"
           : js() ? "errcls(() => " + e + ")" : "errcls(lambda: " + e + ")";
  }

  std::string str_rep() const { return lu() ? "('ab'):rep(3)" : js() ? "'ab'.repeat(3)" : "'ab' * 3"; }
  std::string nul_string() const { return "\"a\\0b\""; }
  std::string pow40() const { return lu() ? "1 << 40" : "2**40"; }
  std::string array_class() const { return rb() ? "Array" : lu() ? "table" : js() ? "Array" : "list"; }
  std::string upper() const { return rb() ? "upcase" : js() ? "toUpperCase" : "upper"; }
  std::string raise_boom() const {
    return rb() ? "raise ArgumentError, 'boom'" : lu() ? "error('boom')" : js() ? "throw new Error('boom')" : "raise ValueError('boom')";
  }
  std::string err_class() const { return rb() ? "ArgumentError" : lu() ? "LuaError" : js() ? "Error" : "ValueError"; }
  std::string raiser_class() const { return rb() ? "RuntimeError" : lu() ? "LuaError" : js() ? "Error" : "ValueError"; }
  std::string zero_div() const { return lu() ? "1 // 0" : js() ? "1n / 0n" : "1 / 0"; }  // JavaScript's 1 / 0 is Infinity
  std::string zero_div_class() const { return lu() ? "LuaError" : js() ? "RangeError" : "ZeroDivisionError"; }
  std::string nil_call() const {
    return rb() ? "nil.foo" : lu() ? "local t = nil; return t.foo" : js() ? "null.foo" : "None.foo";
  }
  std::string nil_call_class() const {
    return rb() ? "NoMethodError" : lu() ? "LuaError" : js() ? "TypeError" : "AttributeError";
  }
  std::string host_cls() const { return py() ? "HostError" : "NfcPoly::HostError"; }
  std::string noop() const { return rb() ? "proc { 5 }" : lu() ? "function() return 5 end" : js() ? "() => 5" : "lambda: 5"; }
  std::string def_twice() const {
    return rb() ? "def twice(n) n * 2 end"
           : lu() ? "function twice(n) return n * 2 end"
           : js() ? "function twice(n) { return n * 2 }" : "def twice(n):\n    return n * 2";
  }
  std::string sum_loop() const {  // twice_c(1) + ... + twice_c(4)
    return rb() ? "(1..4).map { |i| twice_c(i) }.sum"
                : lu() ? "local s = 0 for i = 1, 4 do s = s + twice_c(i) end return s"
                : js() ? "(() => { let s = 0; for (let i = 1; i <= 4; i++) s += twice_c(i); return s; })()"
                       : "sum(twice_c(i) for i in range(1, 5))";
  }
  std::string gc() const {  // js_gc is bound by register_all with the raw QuickJS API (JS_RunGC)
    return rb() ? "GC.start" : lu() ? "collectgarbage(); collectgarbage()" : js() ? "js_gc()" : "import gc\ngc.collect()";
  }
  std::string spawn(int n) const {
    std::string c = std::to_string(n);
    return rb() ? c + ".times { Vec3.new(1, 2, 3) }"
                : lu() ? "for i = 1, " + c + " do Vec3.new(1, 2, 3) end"
                : js() ? "for (let i = 0; i < " + c + "; i++) { new Vec3(1, 2, 3); }"
                       : "for i in range(" + c + "):\n    Vec3(1, 2, 3)";
  }
  std::string keep(const std::string& n, const std::string& e) const { return gref(n) + " = " + e; }
  // A statement that raises a host error out of a loop with a cleanup that must run, and sets the global `flag` to 1.
  std::string ensure_flag() const {
    return rb() ? "begin; [1, 2, 3].each { |i| fail7 if i == 2 }; ensure; $flag = 1; end"
                : lu() ? "local ok, e = pcall(function() for i = 1, 3 do if i == 2 then fail7() end end end) flag = 1 error(e, 0)"
                : js() ? "try { for (const i of [1, 2, 3]) { if (i === 2) fail7(); } } finally { flag = 1; }"
                       : "try:\n    for i in [1, 2, 3]:\n        if i == 2:\n            fail7()\nfinally:\n    flag = 1";
  }
  std::string prelude() const {
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
  Context ctx;
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
  ctx.eval_void(ln, "x = 41");
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
    CHECK(ctx.eval_value(ln, "'ab'").call(L.upper()).as<std::string>() == "AB");
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
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("twice_c(1, 2)")) == "wrong number of arguments (given 2, expected 1)");
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("twice_c('a')")) == "expected integer, got string");
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
  CHECK(ctx.eval<double>(ln, "pos.x + pos.y + pos.z") == 6.0);
  ctx.eval_void(ln, "pos.x = 42");
  CHECK(st.pos.x == 42);  // the script holds the host's object itself
  ctx.eval_void(ln, L.call1("pos", "scale", "2"));
  CHECK(st.pos.x == 84 && st.pos.y == 4 && st.pos.z == 6);
  CHECK(ctx.eval<double>(ln, L.call0("pos", "len2")) == 84.0 * 84 + 16 + 36);
  CHECK(ctx.eval<std::string>(ln, L.call0("pos", "to_s")) == "(84)");
  CHECK(ctx.eval<bool>(ln, "pos == pos"));
  CHECK(ctx.eval<double>(ln, L.call0(L.ctor("Vec3", "1, 2, 3"), "len2")) == 14.0);
  CHECK(ctx.eval<double>(ln, L.call1(L.ctor("Vec3", "1, 2, 3"), "dot", L.ctor("Vec3", "1, 1, 1"))) == 6.0);
  CHECK(ctx.eval<double>(ln, "vadd(" + L.ctor("Vec3", "1, 2, 3") + ", " + L.ctor("Vec3", "1, 1, 1") + ").x") == 2.0);
  ctx.eval_void(ln, L.fcall0("self_ref") + ".x = 5");
  CHECK(st.pos.x == 5);
  CHECK(ctx.eval<bool>(ln, "is_null(" + L.nil() + ")") && !ctx.eval<bool>(ln, "is_null(pos)"));
  CHECK(ctx.eval<std::string>(ln, L.guard_msg("vadd(1, 2)")) == "expected Vec3, got integer");
  CHECK(ctx.eval<std::string>(ln, L.guard_msg(L.call1(L.ctor("Person", "'a', 1"), "greet", "3"))) == "expected string, got integer");
  {
    Vec3 copy = ctx.eval<Vec3>(ln, L.ctor("Vec3", "7, 8, 9"));  // by value: a copy of the script's object
    CHECK(copy.x == 7 && copy.z == 9);
    Value pv = ctx.eval_value(ln, "pos");
    CHECK(&pv.as<Vec3&>() == &st.pos && pv.as<Vec3*>() == &st.pos && pv.as<Vec3>().x == 5);
    CHECK(ctx.eval_value(ln, L.nil()).as<Vec3*>() == nullptr);
  }
  ctx.eval_void(ln, "line.a.x = 9; " + L.call1("line.b", "scale", "2"));
  CHECK(st.line.a.x == 9 && st.line.b.x == 4);  // class-typed members are shared with their owner
  CHECK(ctx.eval<std::string>(ln, L.call1("bob", "greet", "'al'")) == "hello al, I am bob");
  ctx.eval_void(ln, "bob.name = 'rob'; bob.age = bob.age + 1");
  CHECK(st.bob.name == "rob" && st.bob.age == 31);
  CHECK(ctx.eval<std::string>(ln, L.ctor("Person", "'eve', 5") + ".name") == "eve");
  CHECK(throws<nfcpoly::ScriptError>([&] { ctx.eval_void(ln, L.ctor("Unreg", "")); }));  // registered without a constructor
  ctx.eval_void(ln, "origin.x = 3");  // a set() copy, owned by the script
  CHECK(ctx.eval<double>(ln, "origin.x") == 3.0);
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
    Value arr = ctx.eval_value(ln, "'ab'");
    for (int k = 0; k < 3000; ++k) arr.call(L.upper());
    CHECK(arr.call(L.upper()).as<std::string>() == "AB");
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

// ---- several languages in one Context -----------------------------------------------------------------------------------
static void cross_tests(const std::vector<Lg>& ls) {
  g_lang = "cross";
  std::printf("-- [cross] one context, %zu languages\n", ls.size());
  State st;
  Context ctx;
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
  for (const Lg& L : ls) ctx.eval_void(L.ln(), "pos.x = pos.x + 1");
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
  ctx.eval_void(ls.back().ln(), "shared_obj.x = 99");
  CHECK(obj.as<Vec3&>().x == 99);
  for (const Lg& L : ls) {
    g_lang = L.ln();
    CHECK(ctx.eval<double>(L.ln(), "shared_obj.x") == 99.0);
  }
  g_lang = "cross";
  // a value that is not plain data stays in its own language
  if (ls.size() > 1) {
    const Lg& A = ls[0];
    const Lg& B = ls[1];
    Value fn = ctx.eval_value(A.ln(), A.noop());
    ctx.set("only_here", fn);
    CHECK(ctx.eval<int>(A.ln(), A.rb() ? "only_here.call" : "only_here()") == 5);
    bool hidden = false;  // an undefined name is an error in Ruby and Python, nil in Lua
    try {
      hidden = ctx.eval_value(B.ln(), "only_here").is_nil();
    } catch (const nfcpoly::ScriptError&) {
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
    if (langs.size() > 1) cross_tests(langs);
  } catch (const std::exception& e) {
    std::printf("uncaught exception: %s\n", e.what());
    return 2;
  }
  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
