// nfcpoly host test: exit status 0 when every check passes. Run by tests/poly/run.sh, which builds it with nfcxx
// together with lib/poly/nfcpoly.cpp and the C++-exception libmruby of scripts/setup-poly.sh.
#include <cstdint>
#include <cstdio>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "nfcpoly.hpp"
#include "nfcpoly_mruby.hpp"

using nfcpoly::Context;
using nfcpoly::Value;

static int failures = 0, checks = 0;
#define CHECK(c)                                                          \
  do {                                                                    \
    ++checks;                                                             \
    if (!(c)) {                                                           \
      std::printf("FAIL line %d: %s\n", __LINE__, #c);                    \
      ++failures;                                                         \
    }                                                                     \
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
static int sum(const std::vector<int>& xs) { int t = 0; for (int x : xs) t += x; return t; }
static std::optional<int> half(int x) { if (x % 2) return std::nullopt; return x / 2; }
static std::size_t length_of(std::string_view s) { return s.size(); }

static int run_tests();
int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  try {
    return run_tests();
  } catch (const std::exception& e) {
    std::printf("uncaught exception: %s\n", e.what());
    return 2;
  }
}

template <class Ex, class F>
static bool throws(F f) {
  try {
    f();
  } catch (const Ex&) {
    return true;
  }
  return false;
}

static int run_tests() {
  Context ctx;

  std::printf("-- values, both ways\n");
  CHECK(ctx.eval<int>("ruby", "1 + 2") == 3);
  CHECK(ctx.eval<int>("mruby", "6 * 7") == 42);
  CHECK(ctx.eval<double>("ruby", "1.5 * 4") == 6.0);
  CHECK(ctx.eval<double>("ruby", "3") == 3.0);  // an Integer is accepted where a floating type is asked
  CHECK(ctx.eval<std::string>("ruby", "'ab' * 3") == "ababab");
  CHECK(ctx.eval<std::string>("ruby", "\"a\\0b\"").size() == 3);  // strings are byte strings
  CHECK(ctx.eval<bool>("ruby", "1 < 2") == true);
  CHECK(ctx.eval<bool>("ruby", "1 > 2") == false);
  CHECK(ctx.eval<long long>("ruby", "2**40") == (1LL << 40));
  CHECK(ctx.eval<std::uint8_t>("ruby", "255") == 255);
  CHECK(ctx.eval_value("ruby", "nil").is_nil());
  CHECK(!ctx.eval<std::optional<int>>("ruby", "nil").has_value());
  CHECK(ctx.eval<std::optional<int>>("ruby", "5").value() == 5);
  CHECK((ctx.eval<std::vector<int>>("ruby", "[3, 1, 2].sort") == std::vector<int>{1, 2, 3}));
  CHECK((ctx.eval<std::vector<std::string>>("ruby", "%w[a b c]") == std::vector<std::string>{"a", "b", "c"}));
  CHECK(ctx.eval<std::vector<double>>("ruby", "[1, 2.5]")[1] == 2.5);
  ctx.eval<void>("ruby", "1");
  ctx.eval_void("ruby", "1");
  CHECK(ctx.eval_value("ruby", "").is_nil());
  CHECK(Context::languages().size() == 1 && Context::languages()[0] == "ruby");
  CHECK(throws<nfcpoly::UnsupportedLanguage>([&] { ctx.eval<int>("python", "1"); }));

  std::printf("-- state persists between evals\n");
  ctx.eval_void("ruby", "x = 41");
  CHECK(ctx.eval<int>("ruby", "x + 1") == 42);
  ctx.eval_void("ruby", "def twice(n) n * 2 end");
  CHECK(ctx.eval<int>("ruby", "twice(x)") == 82);

  std::printf("-- Value\n");
  {
    Value v = ctx.eval_value("ruby", "[1, 2, 3]");
    CHECK(v.is_array() && !v.is_nil() && !v.is_int());
    CHECK(v.class_name() == "Array");
    CHECK(v.inspect() == "[1, 2, 3]");
    CHECK(v.call("size").as<int>() == 3);
    CHECK(v.call("include?", 2).as<bool>());
    CHECK(v.call("join", "-").as<std::string>() == "1-2-3");
    CHECK(v.call("join", std::string("+")).as<std::string>() == "1+2+3");
    Value w = v;  // copies keep the array alive on their own
    v = Value();
    CHECK(w.call("first").as<int>() == 1 && v.is_nil());
    Value m = std::move(w);
    CHECK(m.call("last").as<int>() == 3);
    CHECK(ctx.eval_value("ruby", "'x'").call("*", 3).as<std::string>() == "xxx");
    CHECK(throws<nfcpoly::Error>([] { Value().as<int>(); }));
    CHECK(throws<nfcpoly::ScriptError>([&] { m.call("no_such_method"); }));
  }

  std::printf("-- errors\n");
  {
    bool got = false;
    try {
      ctx.eval<int>("ruby", "1 +");
    } catch (const nfcpoly::SyntaxError& e) {
      got = std::string(e.what()).rfind("SyntaxError:", 0) == 0 && std::string(e.what()).find("line 1") != std::string::npos;
    }
    CHECK(got);
    CHECK(ctx.eval<int>("ruby", "x + 1") == 42);  // the interpreter and its top-level locals survive a parse error
    got = false;
    try {
      ctx.eval<int>("ruby", "raise ArgumentError, 'boom'");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "ArgumentError" && e.message() == "boom" && std::string(e.what()) == "ArgumentError: boom";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "1 / 0");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "ZeroDivisionError";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "nil.foo");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "NoMethodError";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "class MyErr < StandardError; end\nraise MyErr, 'mine'");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "MyErr" && e.message() == "mine" && !e.backtrace().empty();
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "'a'");
    } catch (const nfcpoly::ConversionError& e) {
      got = std::string(e.what()) == "expected integer, got string";
    }
    CHECK(got);
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::string>("ruby", "1"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<bool>("ruby", "nil"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::int8_t>("ruby", "300"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<std::uint32_t>("ruby", "-1"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { ctx.eval<int>("ruby", "2**40"); }));
  }

  std::printf("-- bound functions\n");
  {
    int hits = 0;
    ctx.bind_fn("twice_c", +[](int a) { return 2 * a; });
    ctx.bind_fn("scale_fn", &scale_fn);
    ctx.bind_fn("shout", &shout);
    ctx.bind_fn("sum", &sum);
    ctx.bind_fn("half", &half);
    ctx.bind_fn("length_of", &length_of);
    ctx.bind_fn("hit", [&hits](int by) { hits += by; });  // a capturing lambda; a void result is nil
    CHECK(ctx.eval<int>("ruby", "twice_c(21)") == 42);
    CHECK(ctx.eval<double>("ruby", "scale_fn(1.5)") == 15.0);
    CHECK(ctx.eval<std::string>("ruby", "shout('hey')") == "hey!");
    CHECK(ctx.eval<int>("ruby", "sum([1, 2, 3, 4])") == 10);
    CHECK(ctx.eval<int>("ruby", "half(10)") == 5);
    CHECK(ctx.eval_value("ruby", "half(3)").is_nil());
    CHECK(ctx.eval<int>("ruby", "length_of('hello')") == 5);
    CHECK(ctx.eval_value("ruby", "hit(3)").is_nil() && hits == 3);
    CHECK(ctx.eval<int>("ruby", "(1..4).map { |i| twice_c(i) }.sum") == 20);
    CHECK(ctx.eval<std::string>("ruby", "begin; twice_c(1, 2); rescue ArgumentError => e; e.message; end") ==
          "wrong number of arguments (given 2, expected 1)");
    CHECK(ctx.eval<std::string>("ruby", "begin; twice_c('a'); rescue TypeError => e; e.message; end") ==
          "expected integer, got string");
    CHECK(throws<nfcpoly::Error>([&] { ctx.bind_fn("Upper", +[] { return 1; }); }));
    CHECK(throws<nfcpoly::Error>([&] { ctx.bind_fn("a b", +[] { return 1; }); }));
    std::vector<int> big(10000);
    for (int k = 0; k < 10000; ++k) big[k] = k;
    ctx.bind_fn("big", [&big]() -> std::vector<int> { return big; });
    CHECK(ctx.eval<int>("ruby", "sum(big)") == 49995000);
  }

  std::printf("-- bound variables\n");
  {
    int counter = 5;
    std::string label = "a";
    const int limit = 10;
    ctx.bind("counter", counter).bind("label", label).bind("limit", limit);
    CHECK(ctx.eval<int>("ruby", "counter + 1") == 6);
    counter = 7;
    CHECK(ctx.eval<int>("ruby", "counter") == 7);  // read live, not a copy taken at bind time
    ctx.eval_void("ruby", "self.counter = 100; self.label = 'zed'");
    CHECK(counter == 100 && label == "zed");
    CHECK(ctx.eval<int>("ruby", "limit") == 10);
    CHECK(ctx.eval<std::string>("ruby", "begin; self.limit = 1; rescue NoMethodError; 'ro'; end") == "ro");
    ctx.set("answer", 42).set("greeting", std::string("hi")).set("pi", 3.25);
    CHECK(ctx.eval<int>("ruby", "answer") == 42);
    CHECK(ctx.eval<std::string>("ruby", "greeting + '!'") == "hi!");
    CHECK(ctx.eval<double>("ruby", "pi * 2") == 6.5);
  }

  std::printf("-- registered classes\n");
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
  ctx.def_class<Person>("Person").ctor<std::string, int>().field("name", &Person::name).field("age", &Person::age).method("greet", &Person::greet);
  ctx.def_class<Unregistered>("Unreg");  // a class registered without a constructor
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Vec3>("Again"); }));
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Unregistered>("Another"); }));
  CHECK(throws<nfcpoly::Error>([&] { ctx.def_class<Person>("lower"); }));
  {
    Vec3 pos{1, 2, 3};
    ctx.bind("pos", pos);
    CHECK(ctx.eval<double>("ruby", "pos.x + pos.y + pos.z") == 6.0);
    ctx.eval_void("ruby", "pos.x = 42");
    CHECK(pos.x == 42);  // the script holds the host's object itself
    ctx.eval_void("ruby", "pos.scale(2)");
    CHECK(pos.x == 84 && pos.y == 4 && pos.z == 6);
    CHECK(ctx.eval<double>("ruby", "pos.len2") == 84.0 * 84 + 16 + 36);
    CHECK(ctx.eval<std::string>("ruby", "pos.to_s") == "(84)");
    CHECK(ctx.eval<bool>("ruby", "pos.equal?(pos)"));

    CHECK(ctx.eval<double>("ruby", "Vec3.new(1, 2, 3).len2") == 14.0);
    CHECK(ctx.eval<double>("ruby", "Vec3.new(1, 2, 3).dot(Vec3.new(1, 1, 1))") == 6.0);
    ctx.bind_fn("vadd", [](const Vec3& a, const Vec3& b) { return a.plus(b); });  // a result by value is a new object
    ctx.bind_fn("self_ref", [&pos]() -> Vec3& { return pos; });                   // a reference result is shared
    ctx.bind_fn("is_null", [](const Vec3* p) { return p == nullptr; });
    ctx.bind_fn("unreg", [] { return Unregistered{}; });
    CHECK(ctx.eval<double>("ruby", "vadd(Vec3.new(1, 2, 3), Vec3.new(1, 1, 1)).x") == 2.0);
    ctx.eval_void("ruby", "self_ref.x = 5");
    CHECK(pos.x == 5);
    CHECK(ctx.eval<bool>("ruby", "is_null(nil)") && !ctx.eval<bool>("ruby", "is_null(pos)"));
    CHECK(ctx.eval<std::string>("ruby", "begin; vadd(1, 2); rescue TypeError => e; e.message; end") == "expected Vec3, got integer");
    CHECK(ctx.eval<std::string>("ruby", "begin; Person.new('a', 1).greet(3); rescue TypeError => e; e.message; end") ==
          "expected string, got integer");

    Vec3 copy = ctx.eval<Vec3>("ruby", "Vec3.new(7, 8, 9)");  // by value: a copy of the script's object
    CHECK(copy.x == 7 && copy.z == 9);
    Value pv = ctx.eval_value("ruby", "pos");
    CHECK(&pv.as<Vec3&>() == &pos && pv.as<Vec3*>() == &pos && pv.as<Vec3>().x == 5);
    CHECK(ctx.eval_value("ruby", "nil").as<Vec3*>() == nullptr);

    ctx.eval_void("ruby", "class P3 < Vec3; def norm1; x.abs + y.abs + z.abs; end; end");  // a script subclass
    CHECK(ctx.eval<double>("ruby", "P3.new(1, -2, 3).norm1") == 6.0);

    Line line{{1, 1, 1}, {2, 2, 2}};
    ctx.bind("line", line);
    ctx.eval_void("ruby", "line.a.x = 9; line.b.scale(2)");
    CHECK(line.a.x == 9 && line.b.x == 4);  // class-typed members are shared with their owner

    Person bob("bob", 30);
    ctx.bind("bob", bob);
    CHECK(ctx.eval<std::string>("ruby", "bob.greet('al')") == "hello al, I am bob");
    ctx.eval_void("ruby", "bob.name = 'rob'; bob.age += 1");
    CHECK(bob.name == "rob" && bob.age == 31);
    CHECK(ctx.eval<std::string>("ruby", "Person.new('eve', 5).name") == "eve");
    CHECK(ctx.eval<std::string>("ruby", "begin; Unreg.new; rescue NoMethodError => e; 'noctor'; end") == "noctor");

    ctx.set("origin", Vec3{0, 0, 0});  // a copy, owned by the script
    ctx.eval_void("ruby", "origin.x = 3");
    CHECK(ctx.eval<double>("ruby", "origin.x") == 3.0);
  }

  std::printf("-- an object of a class nobody registered\n");
  {
    struct NotRegistered {
      int v = 1;
    };
    ctx.bind_fn("make_nr", [] { return NotRegistered{}; });
    CHECK(ctx.eval<std::string>("ruby", "begin; make_nr; rescue TypeError => e; e.message; end").find("def_class") != std::string::npos);
  }

  std::printf("-- the script's GC releases script-owned objects\n");
  {
    ctx.eval_void("ruby", "GC.start");
    int base = Vec3::live;
    ctx.eval_void("ruby", "2000.times { Vec3.new(1, 2, 3) }");
    ctx.eval_void("ruby", "GC.start");
    CHECK(Vec3::live == base);
    Value keep = ctx.eval_value("ruby", "Vec3.new(1, 2, 3)");  // a Value roots its object
    ctx.eval_void("ruby", "GC.start; GC.start");
    CHECK(Vec3::live == base + 1 && keep.as<Vec3&>().x == 1);
    keep = Value();
    ctx.eval_void("ruby", "GC.start");
    CHECK(Vec3::live == base);
    for (int k = 0; k < 3000; ++k) ctx.eval<int>("ruby", "1 + 1");  // the arena does not grow without bound
    Value arr = ctx.eval_value("ruby", "'ab'");
    for (int k = 0; k < 3000; ++k) arr.call("upcase");
    CHECK(arr.call("upcase").as<std::string>() == "AB");
  }
  {
    int before = Vec3::live;
    {
      Context c2;
      c2.def_class<Vec3>("Vec3").ctor<double, double, double>();
      c2.eval_void("ruby", "$keep = Vec3.new(1, 2, 3)");
      CHECK(Vec3::live == before + 1);
    }
    CHECK(Vec3::live == before);  // closing the interpreter finalizes what the script still owned
  }

  std::printf("-- a Value outlives its context safely\n");
  {
    Value arr, num, obj;
    {
      Context c3;
      c3.def_class<Vec3>("Vec3").ctor<double, double, double>();
      arr = c3.eval_value("ruby", "[1, 2, 3]");
      num = c3.eval_value("ruby", "42");
      obj = c3.eval_value("ruby", "Vec3.new(1, 2, 3)");
    }
    CHECK(num.as<int>() == 42);                    // plain values keep working
    CHECK(obj.as<Vec3&>().z == 3);                 // and so does an object the Value co-owns
    CHECK(!arr.is_array());                        // the interpreter is gone: nothing can be asked of it any more
    CHECK(throws<nfcpoly::Error>([&] { arr.call("size"); }));
    CHECK(throws<nfcpoly::Error>([&] { num.call("to_s"); }));
    CHECK(throws<nfcpoly::ConversionError>([&] { arr.as<std::vector<int>>(); }));
    arr = Value();
    obj = Value();
  }

  std::printf("-- C++ exceptions through scripts\n");
  {
    ctx.bind_fn("thrower", []() -> int { throw std::runtime_error("host boom"); });
    ctx.bind_fn("fail7", []() -> int { throw HostFail("seven", 7); });
    ctx.bind_fn("throw_int", []() -> int { throw 42; });
    // a script rescues a host exception as an NfcPoly::HostError (a RuntimeError)
    auto r = ctx.eval<std::vector<std::string>>("ruby", "begin; thrower; rescue => e; [e.class.to_s, e.message]; end");
    CHECK(r.size() == 2 && r[0] == "NfcPoly::HostError" && r[1] == "host boom");
    CHECK(ctx.eval<std::string>("ruby", "begin; thrower; rescue RuntimeError => e; 'rt'; end") == "rt");
    CHECK(ctx.eval<std::string>("ruby", "begin; throw_int; rescue => e; e.message; end") == "unknown C++ exception");
    // nothing rescued it: the host gets the original exception, type and payload intact
    bool got = false;
    try {
      ctx.eval<int>("ruby", "fail7");
    } catch (const HostFail& f) {
      got = f.code == 7 && std::string(f.what()) == "seven";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "thrower");
    } catch (const std::runtime_error& e) {
      got = std::string(e.what()) == "host boom";
    }
    CHECK(got);
    got = false;
    try {
      ctx.eval<int>("ruby", "throw_int");
    } catch (int v) {
      got = v == 42;
    }
    CHECK(got);
    // through script frames in between (a block called by a C function of the interpreter), with ensure
    ctx.eval_void("ruby", "$flag = 0");
    got = false;
    try {
      ctx.eval<int>("ruby", "begin; [1, 2, 3].each { |i| fail7 if i == 2 }; ensure; $flag = 1; end");
    } catch (const HostFail&) {
      got = true;
    }
    CHECK(got && ctx.eval<int>("ruby", "$flag") == 1);
    CHECK(ctx.eval<int>("ruby", "twice_c(4)") == 8);  // and the interpreter is still consistent

    // A script raise passes through a bound C++ function (raw mruby API: mruby's own throw) and releases its RAII objects.
    mrb_state* mrb = nfcpoly::mruby_state(ctx);
    ctx.bind_fn("with_guard", [mrb](Value proc) -> int {
      Guard g;
      mrb_funcall(mrb, nfcpoly::mruby_raw(proc), "call", 0);
      return 1;
    });
    int d0 = Guard::destroyed;
    CHECK(ctx.eval<std::string>("ruby", "begin; with_guard(proc { raise 'inner' }); rescue => e; e.message; end") == "inner");
    CHECK(Guard::alive == 0 && Guard::destroyed == d0 + 1);
    CHECK(ctx.eval<int>("ruby", "with_guard(proc { 5 })") == 1 && Guard::alive == 0);

    // The same through the library's own Value::call: the script exception comes back to the script as that object.
    ctx.bind_fn("with_guard2", [](Value proc) -> int {
      Guard g;
      proc.call("call");
      return 1;
    });
    d0 = Guard::destroyed;
    CHECK(ctx.eval<std::string>("ruby", "begin; with_guard2(proc { raise MyErr, 'x' }); rescue MyErr => e; e.message; end") == "x");
    CHECK(Guard::alive == 0 && Guard::destroyed == d0 + 1);
    got = false;
    try {
      ctx.eval<int>("ruby", "with_guard2(proc { raise 'deep' })");
    } catch (const nfcpoly::ScriptError& e) {
      got = e.class_name() == "RuntimeError" && e.message() == "deep";
    }
    CHECK(got && Guard::alive == 0);

    // a host exception thrown under a callback survives a round trip through script code that does not rescue it
    ctx.bind_fn("with_guard3", [](Value proc) -> int {
      Guard g;
      proc.call("call");
      return 1;
    });
    got = false;
    try {
      ctx.eval<int>("ruby", "with_guard3(proc { fail7 })");
    } catch (const HostFail& f) {
      got = f.code == 7;
    }
    CHECK(got && Guard::alive == 0);

    // re-entrancy: a bound function that evaluates script code itself
    ctx.bind_fn("nested", [&ctx]() { return ctx.eval<int>("ruby", "40 + 2"); });
    CHECK(ctx.eval<int>("ruby", "nested + 1") == 43);
  }

  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
