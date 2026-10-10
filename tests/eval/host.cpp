// nfceval host test: exit status 0 when every check passes. Run by tests/eval/run.sh, which sets
// NFCEVAL_CACHE, NFCXX, NFCXX_BACKEND and passes the include directory of vec3.hpp as argv[1].
#include <cstdio>
#include <string>

// The library is included as one translation unit: nfcxx currently fails to link two objects that both
// use hosted libstdc++ templates such as std::string (duplicate std::allocator<char> members), see
// docs/notes/eval.md.
#include "nfceval.cpp"
#include "vec3.hpp"

double Vec3::len2() const { return x * x + y * y + z * z; }
void Vec3::scale(double k) { x *= k; y *= k; z *= k; }
int Counter::bump(int by) { n += by; return n; }

static int failures = 0;
#define CHECK(c)                                                          \
  do {                                                                    \
    if (!(c)) {                                                           \
      std::printf("FAIL line %d: %s\n", __LINE__, #c);                    \
      ++failures;                                                         \
    }                                                                     \
  } while (0)

static double scale_fn(double v) { return v * 10.0; }
static int calls = 0;
static int bump_global(int a, int b) { ++calls; return a + b; }
static void say(const std::string& s) { std::printf("say: %s\n", s.c_str()); }

static int run_tests(int argc, char** argv);
int main(int argc, char** argv) {
  try {
    return run_tests(argc, argv);
  } catch (const std::exception& e) {
    std::printf("uncaught exception: %s\n", e.what());
    return 2;
  }
}

static int run_tests(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::string inc = argc > 1 ? argv[1] : ".";
  nfceval::Engine eng;
  eng.add_flag("-I" + inc);
  eng.include("<vector>");
  eng.include("vec3.hpp");

  int counter = 0;
  Vec3 pos{1, 2, 3};
  eng.bind("counter", counter);
  eng.bind("pos", pos);

  std::printf("-- scalar and struct bindings by reference; statements and `return`\n");
  CHECK(eng.eval<int>("counter += 2; return counter * 3;") == 6);
  CHECK(counter == 2);
  CHECK(eng.eval<double>("return pos.x + pos.y + pos.z;") == 6.0);
  eng.eval_void("pos.x = 42; counter = 7;");
  CHECK(pos.x == 42 && counter == 7);

  std::printf("-- bare expression, and stmts; expr\n");
  CHECK(eng.eval<int>("counter * 2") == 14);
  CHECK(eng.eval<int>("counter = 5; counter + 1") == 6 && counter == 5);
  CHECK(eng.eval<int>("int s = 0; for (int i = 0; i < 4; ++i) { s += i; } return s;") == 6);

  std::printf("-- result types\n");
  CHECK(eng.eval<bool>("counter == 5") == true);
  CHECK(eng.eval<bool>("counter == 6") == false);
  CHECK(eng.eval<double>("1.5 * 2") == 3.0);
  CHECK(eng.eval<std::string>("std::string(\"count=\") + std::to_string(counter)") == "count=5");
  CHECK(eng.eval<long>("(long)counter * 1000000000L") == 5000000000L);

  std::printf("-- const binding: reads work, writes are rejected at compile time\n");
  const int limit = 99;
  eng.bind("limit", limit);
  CHECK(eng.eval<int>("limit + 1") == 100);
  bool cerr_caught = false;
  try {
    eng.eval_void("limit = 1;");
  } catch (const nfceval::CompileError& e) {
    cerr_caught = std::string(e.what()).find("snippet") != std::string::npos;
  }
  CHECK(cerr_caught);

  std::printf("-- function bindings: function pointer, plain function, capturing lambda, void/string args\n");
  eng.bind_fn("scale", &scale_fn);
  eng.bind_fn("add", bump_global);
  int captured = 100;
  eng.bind_fn("addc", [&captured](int a) { captured += a; return captured; });
  eng.bind_fn("say", say);
  CHECK(eng.eval<double>("scale(pos.y)") == 20.0);
  CHECK(eng.eval<int>("add(counter, 1)") == 6 && calls == 1);
  CHECK(eng.eval<int>("addc(5) + addc(6)") == 105 + 111 && captured == 111);
  eng.eval_void("say(\"hello from the snippet\")");

  std::printf("-- methods on bound objects: inline, out of line (exported by the host), and bind_method\n");
  CHECK(eng.eval<double>("pos.dot(pos)") == 42.0 * 42 + 4 + 9);
  CHECK(eng.eval<double>("pos.len2()") == 42.0 * 42 + 4 + 9);
  eng.eval_void("pos.scale(0.5);");
  CHECK(pos.x == 21 && pos.y == 1);
  Counter cn;
  eng.bind("cn", cn);
  CHECK(eng.eval<int>("cn.bump(3); return cn.bump(4);") == 7 && cn.n == 7);
  eng.bind_method("Vec3_len2", &Vec3::len2);
  eng.bind_method("Vec3_scale", &Vec3::scale);
  eng.bind_method("Counter_bump", &Counter::bump);
  CHECK(eng.eval<double>("Vec3_scale(pos, 2); return Vec3_len2(pos);") == 42.0 * 42 + 4 + 9);
  CHECK(eng.eval<int>("Counter_bump(cn, 1)") == 8);

  std::printf("-- headers' types work through the prelude too\n");
  CHECK(eng.eval<int>("std::vector<int> v{1, 2, 3}; v.push_back(4); return (int)v.size();") == 4);

  std::printf("-- multiple evals reuse the cache: same snippet and bindings, no new compile or load\n");
  unsigned c0 = eng.compiles(), l0 = eng.loads();
  for (int i = 0; i < 5; ++i) {
    counter = i;
    CHECK(eng.eval<int>("counter * 2") == 2 * i);
  }
  CHECK(eng.compiles() - c0 <= 1 && eng.loads() - l0 <= 1);
  c0 = eng.compiles(); l0 = eng.loads();
  CHECK(eng.eval<int>("counter * 2") == 8);
  CHECK(eng.compiles() == c0 && eng.loads() == l0);
  {
    // a second engine with the same cache directory loads the shared object without compiling
    nfceval::Engine eng2;
    eng2.add_flag("-I" + inc);
    eng2.include("<vector>");
    eng2.include("vec3.hpp");
    int counter2 = 21;
    eng2.bind("counter", counter2);
    eng2.bind("pos", pos);
    eng2.bind("limit", limit);
    eng2.bind_fn("scale", &scale_fn);
    eng2.bind_fn("add", bump_global);
    eng2.bind_fn("addc", [&captured](int a) { return a; });
    eng2.bind_fn("say", say);
    eng2.bind("cn", cn);
    eng2.bind_method("Vec3_len2", &Vec3::len2);
    eng2.bind_method("Vec3_scale", &Vec3::scale);
    eng2.bind_method("Counter_bump", &Counter::bump);
    CHECK(eng2.eval<int>("counter * 2") == 42);
    CHECK(eng2.compiles() == 0 && eng2.loads() == 1);
  }

  std::printf("-- compile error: exception with the compiler's output, snippet line numbers\n");
  bool got = false;
  try {
    eng.eval<int>("int a = 1;\nint b = ;\nreturn a + b;");
  } catch (const nfceval::CompileError& e) {
    std::string w = e.what();
    got = w.find("snippet") != std::string::npos && w.find("line 2") != std::string::npos;
    if (!got) std::printf("compile error text:\n%s\n", w.c_str());
  }
  CHECK(got);
  got = false;
  try {
    eng.eval<int>("return undefined_name;");
  } catch (const nfceval::Error& e) {
    got = std::string(e.what()).find("undefined_name") != std::string::npos;
  }
  CHECK(got);

  std::printf("-- exception thrown by the snippet comes back as RuntimeError; the engine still works afterwards\n");
  got = false;
  try {
    eng.eval<int>("if (counter >= 0) throw std::runtime_error(\"boom from snippet\"); return 1;");
  } catch (const nfceval::RuntimeError& e) {
    got = std::string(e.what()) == "boom from snippet";
  }
  CHECK(got);
  got = false;
  try {
    eng.eval_void("throw 42;");
  } catch (const nfceval::RuntimeError& e) {
    got = std::string(e.what()) == "unknown exception";
  }
  CHECK(got);
  got = false;
  try {
    eng.eval<int>("counter = 1;");  // statements only: no value
  } catch (const nfceval::RuntimeError& e) {
    got = std::string(e.what()).find("did not return") != std::string::npos;
  }
  CHECK(got);
  CHECK(eng.eval<int>("counter + 1") == 2 && counter == 1);

  std::printf("-- rebinding: same name, new object (same type: no recompile), then a different type\n");
  int other = 1000;
  eng.bind("counter", other);
  c0 = eng.compiles();
  CHECK(eng.eval<int>("counter * 2") == 2000);
  CHECK(eng.compiles() == c0);
  eng.eval_void("counter = 1;");
  CHECK(other == 1);
  double dval = 2.5;
  eng.bind("counter", dval);
  CHECK(eng.eval<double>("counter * 2") == 5.0);
  eng.eval_void("counter = 9.5;");
  CHECK(dval == 9.5);
  eng.unbind("counter");
  got = false;
  try {
    eng.eval<int>("counter");
  } catch (const nfceval::CompileError&) {
    got = true;
  }
  CHECK(got);

  std::printf("-- unspellable type: a clear error rather than a broken compile\n");
  auto lam = [] { return 1; };
  got = false;
  try {
    eng.bind("lam", lam);
  } catch (const nfceval::Error&) {
    got = true;
  }
  CHECK(got);

  std::printf("-- a missing driver is an Error, not a CompileError\n");
  {
    nfceval::Engine bad;
    bad.set_driver("/nonexistent/nfcxx");
    got = false;
    try {
      bad.eval<int>("1");
    } catch (const nfceval::CompileError&) {
    } catch (const nfceval::Error&) {
      got = true;
    }
    CHECK(got);
  }

  std::printf("-- prelude: globals with constructors and destructors in the snippet's translation unit\n");
  {
    nfceval::Engine e3;
    e3.add_flag("-I" + inc);
    e3.prelude("struct G { int v; G() : v(11) {} ~G() {} }; static G g_global; static int helper(int x) { return x + g_global.v; }");
    CHECK(e3.eval<int>("helper(1)") == 12);
  }

  if (failures) std::printf("%d check(s) failed\n", failures);
  else std::printf("all checks passed\n");
  return failures ? 1 : 0;
}
