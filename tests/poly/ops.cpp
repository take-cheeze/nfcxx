// nfcpoly: optional trailing arguments (method_fn / bind_fn with min_args), computed properties (property_fn) and operator methods
// (the Python-named methods __add__, __radd__, ... that the Python, Lua and Ruby backends turn into their operators). Built by
// tests/poly/run.sh next to host.cpp with the same TEST_* macros; exit status 0 when every check passes.
#include <cstdio>
#include <string>

#include "nfcpoly.hpp"

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

struct Num {
  double v;
  Num() : v(0) {}
  explicit Num(double x) : v(x) {}
};

static double value_of(const Value& x) {  // a number, or a Num
  if (x.is_int()) return static_cast<double>(x.as<long long>());
  if (x.is_float()) return x.as<double>();
  return x.as<const Num*>()->v;
}

static Num scaled(const Num& n, const Value& k, const Value& off) {  // k defaults to 1, off to 0
  return Num(n.v * (k.is_nil() ? 1.0 : value_of(k)) + (off.is_nil() ? 0.0 : value_of(off)));
}

static void setup(Context& ctx) {
  auto c = ctx.def_class<Num>("Num");
  c.ctor<double>().field("v", &Num::v);
  c.method_fn("scaled", scaled, 0);   // scaled(), scaled(k), scaled(k, off)
  c.method_fn("scaled1", scaled, 1);  // scaled(k), scaled(k, off)
  c.property_fn("twice", [](const Num& n) { return n.v * 2; });
  c.property_fn("half", [](const Num& n) { return n.v / 2; }, [](Num& n, double h) { n.v = h * 2; });
  // operators, by their Python names
  c.method_fn("__add__", [](const Num& a, const Value& b) { return Num(a.v + value_of(b)); });
  c.method_fn("__radd__", [](const Num& a, const Value& b) { return Num(value_of(b) + a.v); });
  c.method_fn("__sub__", [](const Num& a, const Value& b) { return Num(a.v - value_of(b)); });
  c.method_fn("__rsub__", [](const Num& a, const Value& b) { return Num(value_of(b) - a.v); });
  c.method_fn("__mul__", [](const Num& a, const Value& b) { return Num(a.v * value_of(b)); });
  c.method_fn("__truediv__", [](const Num& a, const Value& b) { return Num(a.v / value_of(b)); });
  c.method_fn("__neg__", [](const Num& a) { return Num(-a.v); });
  c.method_fn("__lt__", [](const Num& a, const Value& b) { return Num(a.v < value_of(b) ? 1 : 0); });  // a value, not a boolean
  c.method_fn("__eq__", [](const Num& a, const Value& b) { return Num(a.v == value_of(b) ? 1 : 0); });
  c.method_fn("__getitem__", [](const Num& a, const Value& i) { return a.v + value_of(i); });
  c.method_fn("__str__", [](const Num& a) { return "Num(" + std::to_string(static_cast<int>(a.v)) + ")"; });
  ctx.bind_fn("addopt", [](const Value& a, const Value& b) { return value_of(a) + (b.is_nil() ? 100.0 : value_of(b)); }, 1);
}

// What a language can do, and how it spells it.
struct Lg {
  const char* id;
  const char* make;     // an expression for Num(4)
  bool colon;           // Lua: n:scaled()
  bool go;              // Go: capitalized names
  bool ops;             // the backend maps the operator methods
  bool reflected;       // 1 + n and 10 - n work (not in Ruby: its Integer does not ask the other operand)
  bool compare;         // < and == return the method's value (not in Lua, which turns it into a boolean)
  bool index;           // n[2]
  const char* set_half; // a snippet that assigns n.half = 10 and then gives n.v
  const char* str;      // an expression for the text of Num(4)
};

static void run(const Lg& lg) {
  g_lang = lg.id;
  Context ctx;
  setup(ctx);
  const char* id = lg.id;
  const std::string N = lg.make;
  auto cap = [&](std::string m) {
    if (lg.go) m[0] = static_cast<char>(m[0] - 'a' + 'A');
    return m;
  };
  auto call = [&](const std::string& m, const std::string& args) { return N + (lg.colon ? ":" : ".") + cap(m) + "(" + args + ")"; };
  auto field = [&](const std::string& obj, const std::string& f) { return lg.go ? obj + "." + cap(f) + "()" : obj + "." + f; };
  auto num = [&](const std::string& code) { return ctx.eval<double>(id, code); };
  auto raises = [&](const std::string& code, const char* what) {
    try {
      ctx.eval_void(id, code);
    } catch (const nfcpoly::ScriptError& e) {
      return what == nullptr || e.message().find(what) != std::string::npos;
    } catch (const nfcpoly::SyntaxError&) {
      return lg.go;  // Go is typed: a call with too few arguments does not compile
    }
    return false;
  };
  // optional trailing arguments
  CHECK(num(field(call("scaled", ""), "v")) == 4);
  CHECK(num(field(call("scaled", "2"), "v")) == 8);
  CHECK(num(field(call("scaled", "2, 3"), "v")) == 11);
  CHECK(num(field(call("scaled1", "2"), "v")) == 8);
  CHECK(num(field(call("scaled1", "2, 1"), "v")) == 9);
  CHECK(raises(call("scaled", "1, 2, 3"), "wrong number of arguments"));  // too many
  CHECK(raises(call("scaled1", ""), "wrong number of arguments"));        // too few
  CHECK(num("addopt(1)") == 101 && num("addopt(1, 2)") == 3);
  CHECK(raises("addopt()", "wrong number of arguments"));
  {  // Value::call from C++ takes the optional arguments too
    Value v = ctx.eval_value(id, N);
    CHECK(v.call(cap("scaled")).as<Num>().v == 4);
    CHECK(v.call(cap("scaled"), 3).as<Num>().v == 12);
    CHECK(v.call(cap("scaled1"), 3, 1).as<Num>().v == 13);
  }
  // computed properties: read, read and write, read only
  CHECK(num(field(N, "twice")) == 8);
  CHECK(num(field(N, "half")) == 2);
  CHECK(num(lg.set_half) == 20);
  if (!lg.go) CHECK(raises(N + ".twice = 1", nullptr));
  // operators
  if (lg.ops) {
    CHECK(num("(" + N + " + 1).v") == 5);
    CHECK(num("(" + N + " - 1).v") == 3);
    CHECK(num("(" + N + " * 3).v") == 12);
    CHECK(num("(" + N + " / 8).v") == 0.5);
    CHECK(num("(-" + N + ").v") == -4);
    CHECK(num("(" + N + " + " + N + ").v") == 8);
    if (lg.reflected) {
      CHECK(num("(1 + " + N + ").v") == 5);
      CHECK(num("(10 - " + N + ").v") == 6);
    }
    if (lg.compare) {
      CHECK(num("(" + N + " < 5).v") == 1);  // the method's own result, not a boolean
      CHECK(num("(" + N + " < 3).v") == 0);
      CHECK(num("(" + N + " == 4).v") == 1);
    }
    if (lg.index) CHECK(num(N + "[2]") == 6);
    CHECK(ctx.eval<std::string>(id, lg.str) == "Num(4)");
  }
}

int main() {
#ifdef TEST_PYTHON
  run({"python", "Num(4)", false, false, true, true, true, true, "n = Num(4); n.half = 10; n.v", "str(Num(4))"});
  {  // Python only: 5 > n asks n.__lt__(5) (the swapped comparison); objects stay hashable
    Context ctx;
    setup(ctx);
    g_lang = "python";
    CHECK(ctx.eval<double>("python", "(5 > Num(4)).v") == 1);
    CHECK(ctx.eval<bool>("python", "isinstance(hash(Num(1)), int)"));
  }
#endif
#ifdef TEST_LUA
  run({"lua", "Num.new(4)", true, false, true, true, false, false, "local n = Num.new(4); n.half = 10; return n.v", "tostring(Num.new(4))"});
#endif
#ifdef TEST_RUBY
  run({"ruby", "Num.new(4)", false, false, true, false, true, true, "n = Num.new(4); n.half = 10; n.v", "Num.new(4).to_s"});
#endif
#ifdef TEST_JS
  run({"js", "new Num(4)", false, false, false, false, false, false, "let n = new Num(4); n.half = 10; n.v", ""});
#endif
#ifdef TEST_GO
  run({"go", "NewNum(4)", false, true, false, false, false, false, "n := NewNum(4); n.SetHalf(10); n.V()", ""});
#endif
  if (failures) {
    std::printf("%d of %d checks failed\n", failures, checks);
    return 1;
  }
  std::printf("all %d checks passed\n", checks);
  return 0;
}
