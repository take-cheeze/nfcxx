// Checks of the tier (docs/notes/ast.md, "Tiering") through the C++ API: which functions are compiled and when, that compiled code
// gives the interpreter's results and errors, and what happens when its assumptions fail (a wrong argument type, a function that is
// rebound, a division by zero, too deep a recursion), when a compile fails, and when a second State finds the code in the cache.
// It needs the nfcxx driver: tests/ast/run.sh sets NFCXX. Exit status 0 when every check passes.
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "nfcast.hpp"

using nfcast::Rets;
using nfcast::State;
using nfcast::Thrown;
using nfcast::TierOptions;
using nfcast::Value;

static int failures = 0, checks = 0;
#define CHECK(c)                                                       \
  do {                                                                 \
    ++checks;                                                          \
    if (!(c)) {                                                        \
      std::printf("FAIL line %d: %s\n", __LINE__, #c);                 \
      ++failures;                                                      \
    }                                                                  \
  } while (0)

// Runs CODE as a chunk named "test" and returns its results as text ("1,2.5,true"), or "ERR:" and the error message.
static std::string eval(State& S, const std::string& code) {
  std::string err;
  nfcast::Closure* cl = S.load(code, "test", &err);
  if (!cl) return "SYNTAX:" + err;
  Rets out;
  try {
    S.call(Value::function(cl), nullptr, 0, out);
  } catch (Thrown& t) {
    return "ERR:" + S.tostring(t.v);
  }
  std::string r;
  for (int i = 0; i < out.n; ++i) {
    if (i) r += ",";
    r += S.tostring(out.p[i]);
  }
  return r;
}

static void tier_on(State& S, TierOptions::Mode mode, unsigned threshold, const std::string& cache, const std::string& driver = "") {
  TierOptions o;
  o.mode = mode;
  o.threshold = threshold;
  o.loop_threshold = threshold;
  o.cache_dir = cache;
  o.driver = driver;
  S.enable_tier(o);
}

static std::vector<std::string> g_dirs;  // the temporary directories, removed at the end

static std::string temp_dir(const char* what) {
  std::string t = std::string("/tmp/nfcast-tier-test-") + what + "-XXXXXX";
  char* buf = new char[t.size() + 1];
  std::memcpy(buf, t.c_str(), t.size() + 1);
  std::string r = mkdtemp(buf) ? buf : "";
  delete[] buf;
  if (!r.empty()) g_dirs.push_back(r);
  return r;
}

static void remove_dirs() {
  for (const std::string& d : g_dirs)
    if (d.compare(0, 10, "/tmp/nfcas") == 0) {
      int rc = std::system(("rm -rf '" + d + "'").c_str());
      (void)rc;
    }
}

static bool consistent(State& S) { return S.depth == 0 && S.top == S.stack && S.pcall_depth == 0 && S.cur == nullptr; }

// The same program in a State without a tier and in one with, at threshold 1: the same text out, error messages included.
static void same(State& plain, State& tiered, const std::string& code, const char* what) {
  std::string a = eval(plain, code), b = eval(tiered, code);
  ++checks;
  if (a != b) {
    std::printf("FAIL %s:\n  interpreter: %s\n  tier:        %s\n", what, a.c_str(), b.c_str());
    ++failures;
  }
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  std::string cache = temp_dir("cache");
  CHECK(!cache.empty());

  std::printf("-- off by default\n");
  if (!std::getenv("NFCAST_TIER")) {
    State S;
    S.open_libs();
    CHECK(S.tier == nullptr);
    CHECK(eval(S, "local function f(n) if n < 2 then return n end return f(n - 1) + f(n - 2) end return f(15)") == "610");
    CHECK(S.stats.tier_compiled == 0 && S.stats.tier_calls == 0 && S.stats.tier_compiles == 0);
    CHECK(S.tier_state(Value()) == "off");
  }

  std::printf("-- the first compile, recursion, counters\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 3, cache);
    eval(S, "function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end");
    CHECK(eval(S, "return fib(1), fib(0)") == "1,0");      // two calls: below the threshold
    CHECK(S.stats.tier_compiled == 0 && S.stats.tier_calls == 0);
    CHECK(eval(S, "return fib(20)") == "6765");            // the third call compiles it; the calls it makes inside run as native code
    CHECK(S.stats.tier_compiled == 1 && S.stats.tier_compiles + S.stats.tier_cache_hits == 1);
    CHECK(S.stats.tier_calls > 0 && S.stats.tier_bailouts == 0 && S.stats.tier_failed == 0);
    std::uint64_t before = S.stats.tier_calls;
    CHECK(eval(S, "return fib(30)") == "832040");          // one entry: the whole recursion runs inside the native code
    CHECK(S.stats.tier_calls == before + 1);
    CHECK(eval(S, "return fib(10.0)") == "55.0");          // other argument types: not served, and interpreted
    CHECK(S.stats.tier_bailouts >= 1 && S.stats.tier_guard_misses >= 1);
    nfcast::Closure* cl = S.load("return fib", "test", nullptr);
    Rets o;
    S.call(Value::function(cl), nullptr, 0, o);
    CHECK(S.tier_state(o.first()).find("compiled i->i") != std::string::npos);
    CHECK(consistent(S));
  }

  std::printf("-- a float to an integer kernel\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 2, cache);
    CHECK(eval(S, "function sq(n) return n * n end return sq(3)") == "9");
    CHECK(S.stats.tier_compiled == 0);                      // one call: not hot yet
    CHECK(eval(S, "return sq(3)") == "9");
    CHECK(S.stats.tier_compiled == 1 && S.stats.tier_calls == 1);
    CHECK(eval(S, "return sq(4), sq(5)") == "16,25");
    CHECK(S.stats.tier_calls == 3 && S.stats.tier_bailouts == 0);
    CHECK(eval(S, "return sq(2.5)") == "6.25");            // a float: the integer code is not used, the interpreter answers
    CHECK(S.stats.tier_bailouts == 1 && S.stats.tier_guard_misses == 1 && S.stats.tier_aborts == 0);
    CHECK(S.stats.tier_calls == 3 && S.stats.tier_compiled == 1);
    CHECK(eval(S, "return sq(1.5)") == "2.25");            // the second float call makes the function hot for floats: a version for them
    CHECK(S.stats.tier_compiled == 2 && S.stats.tier_calls == 4 && S.stats.tier_bailouts == 1);
    CHECK(eval(S, "return sq(2.5), sq(3)") == "6.25,9");
    CHECK(S.stats.tier_calls == 6 && S.stats.tier_bailouts == 1);
    CHECK(eval(S, "return sq(true)") == "ERR:test:1: attempt to perform arithmetic on a boolean value (local 'n')");
    CHECK(eval(S, "return sq()").compare(0, 4, "ERR:") == 0);   // a missing argument
    CHECK(eval(S, "return sq('3')") == "9");                // a string: the interpreter converts it
    CHECK(S.stats.tier_calls == 6);
    CHECK(consistent(S));
  }

  std::printf("-- a number that is an integer or a float as the run goes\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    auto state = [](State& St, const char* name) {
      nfcast::Closure* c = St.load(std::string("return ") + name, "test", nullptr);
      Rets r;
      St.call(Value::function(c), nullptr, 0, r);
      return St.tier_state(r.first());
    };
    eval(S, "function acc(n, x) local s = 0 for i = 1, n do s = s + x end return s end");
    CHECK(eval(S, "return acc(4, 0.5)") == "2.0");                  // the sum starts as an integer and becomes a float
    CHECK(S.stats.tier_compiled == 1 && S.stats.tier_calls == 1 && S.stats.tier_bailouts == 0);
    CHECK(eval(S, "return acc(0, 0.5), math.type(acc(0, 0.5))") == "0,integer");   // the loop does not run: the result is still the integer
    CHECK(S.stats.tier_calls == 3);
    CHECK(eval(S, "return math.type(acc(3, 2)), math.type(acc(3, 2.0)), acc(3, 2), acc(3, 2.0)") == "integer,float,6,6.0");
    CHECK(state(S, "acc").find("compiled if->n") != std::string::npos);   // n: an integer or a float
    CHECK(state(S, "acc").find("compiled ii->i") != std::string::npos);   // with integers only it stays an integer
    CHECK(S.stats.tier_bailouts == 0 && S.stats.tier_aborts == 0);
    // an integer that wraps, then a float
    CHECK(eval(S, "function wr(n) local s = 9223372036854775807 for i = 1, n do s = s + 1 end if n > 3 then s = s + 0.5 end return s end return wr(2), wr(4)") ==
          "-9223372036854775807,-9.2233720368548e+18");
    CHECK(state(S, "wr").find("compiled i->n") != std::string::npos);
    // a parameter that is given a float: it is a number of either kind inside, and an integer on the way in
    CHECK(eval(S, "function pm(a) local x = a x = x + 1 x = x + 0.5 return x end return pm(1), pm(1.5)") == "2.5,3.0");
    CHECK(state(S, "pm").find("compiled i->n") != std::string::npos && state(S, "pm").find("compiled f->f") != std::string::npos);
    // the result of a call that is a number of either kind, passed on to a callee that then has a parameter of that type
    CHECK(eval(S, "function f2(x) if x > 5 then return x * 0.5 end return x end function g2(x) return f2(x) + f2(x + 5) end return g2(1), g2(2), g2(10)") == "4.0,5.5,12.5");
    CHECK(state(S, "g2").find("compiled i->n") != std::string::npos);
    // bitwise operators on it: a float with an integer value is converted, any other float abandons the run
    CHECK(eval(S, "function bits(a, b) local x = a if b > 0 then x = x + 0.0 end return (x & 7) + (x << 2) end return bits(5, 0), bits(5, 1), bits(-3, 2)") == "25,25,-7");
    CHECK(state(S, "bits").find("compiled ii->i") != std::string::npos);
    CHECK(eval(S, "function half(a, b) local x = 1 if b > 0 then x = a / 2 end return x & 1 end return half(5, 0), half(4, 1)") == "1,0");
    std::uint64_t ab = S.stats.tier_aborts, calls = S.stats.tier_calls;
    CHECK(eval(S, "return pcall(half, 5, 1)") == "false,test:1: number (local 'x') has no integer representation");
    CHECK(S.stats.tier_aborts == ab + 1 && S.stats.tier_calls == calls);   // the compiled code started, found 2.5, and left it to the interpreter
    // `//` and `%` of two integers at run time by zero: the interpreter's error; with a float on either side there is none
    CHECK(eval(S, "function dd(a, b, c) local x = a local y = b if c then x = 1.5 y = 0 end return x // y end return dd(7, 2, false), dd(7, 2, true), dd(7, 0, true)") == "3,inf,inf");
    ab = S.stats.tier_aborts;
    CHECK(eval(S, "return pcall(dd, 7, 0, false)") == "false,test:1: attempt to divide by zero");
    CHECK(S.stats.tier_aborts == ab + 1);
    CHECK(eval(S, "function mm(a, b, c) local x = a local y = b if c then x = 1.5 y = 0 end return x % y end return mm(7, 4, false), pcall(mm, 7, 0, false)") ==
          "3,false,test:1: attempt to perform 'n%0'");
    CHECK(consistent(S));
    // a call made while a variable still had the type it was later widened from does not stand in the way: h(F) is not a kernel, h(N) is
    CHECK(eval(S, "function h3(a) return a & 3 end function g3(c) local x = 2.0 local r = h3(x) if c then x = 3 end return h3(x) + r end return g3(true), g3(false)") == "5,4");
    CHECK(state(S, "g3").find("compiled b->i") != std::string::npos);
    CHECK(consistent(S));
  }

  std::printf("-- mutual recursion, calls through upvalues and globals, numeric free variables\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    eval(S, "function iseven(n) if n == 0 then return true end return isodd(n - 1) end\n"
            "function isodd(n) if n == 0 then return false end return iseven(n - 1) end");
    CHECK(eval(S, "return iseven(10), isodd(10), iseven(7)") == "true,false,false");
    CHECK(S.stats.tier_compiled >= 1 && S.stats.tier_calls >= 3 && S.stats.tier_bailouts == 0);
    CHECK(eval(S, "local k = 3 local function add(x) return x + k end local function f(x) return add(x) * 2 end return f(1), f(2), f(3)") == "8,10,12");
    CHECK(eval(S, "BASE = 10 function g(x) return x + BASE end return g(1), g(2)") == "11,12");
    std::uint64_t calls = S.stats.tier_calls, bail = S.stats.tier_bailouts;
    CHECK(eval(S, "BASE = 20 return g(1)") == "21");        // a global changed: the value is read again at each entry
    CHECK(S.stats.tier_calls == calls + 1 && S.stats.tier_bailouts == bail);
    CHECK(eval(S, "BASE = 0.5 return g(1)") == "1.5");      // ... but its type is part of what the code assumed
    CHECK(S.stats.tier_bailouts == bail + 1);
    CHECK(eval(S, "BASE = nil return pcall(g, 1)").compare(0, 5, "false") == 0);
    CHECK(consistent(S));
  }

  std::printf("-- a function rebound after it was compiled\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    CHECK(eval(S, "local function f(x) return x + 1 end local function g(x) return f(x) * 2 end\n"
                  "local a, b = g(1), g(2)\n"
                  "f = function(x) return x + 100 end\n"
                  "local c = g(1)\n"
                  "f = function(x) return x * 3 end\n"
                  "return a, b, c, g(1), g(5)") == "4,6,202,6,30");
    CHECK(S.stats.tier_bailouts >= 2);
    // a global rebound to a function that is not a kernel
    CHECK(eval(S, "function h(x) return x - 1 end function k(x) return h(x) + h(x) end\n"
                  "local a = k(10)\n"
                  "h = function(x) return tostring(x) end\n"
                  "return a, k(10)") == "18,20");   // a string result is converted by the interpreter's addition
    // closures of one function with different upvalues: the code reads each closure's own
    CHECK(eval(S, "local function make(k) return function(x) return x * k end end\n"
                  "local m2, m3 = make(2), make(3)\n"
                  "local cur = m2\n"
                  "local function call(x) return cur(x) end\n"
                  "local a, b = call(10), call(20)\n"
                  "cur = m3\n"
                  "local c = call(10)\n"
                  "cur = make(1.5)\n"
                  "return a, b, c, call(10), call(2)") == "20,40,30,15.0,3.0");
    CHECK(consistent(S));
  }

  std::printf("-- the interpreter's results and errors, compared\n");
  {
    State plain, tiered;
    plain.open_libs();
    tiered.open_libs();
    tier_on(tiered, TierOptions::Sync, 1, cache);
    const char* progs[] = {
        // wraparound
        "local function f(a, b) return a * b, a + b, a - b end local function g(a, b) return a * b end local function h(a, b) return a + b end "
        "return g(math.maxinteger, 2), g(math.mininteger, -1), g(3037000500, 3037000500), h(math.maxinteger, 1), h(math.mininteger, -1)",
        "local function n(a) return -a end return n(math.mininteger), n(5), n(2.5)",
        "local function s(n) local x = math.maxinteger - 2 for i = 1, n do x = x + 1 end return x end return s(1), s(5), s(100)",
        // division, modulo, floor division and their zero cases
        "local function d(a, b) return a // b end local function m(a, b) return a % b end return d(7, 2), d(-7, 2), d(7, -2), d(7.0, 2), d(1, 0.0), d(math.mininteger, -1), m(7, 3), m(-7, 3), m(7, -3), m(5.5, 2), m(1, math.huge), m(math.mininteger, -1)",
        "local function d(a, b) return a // b end d(1, 1) return d(1, 0)",
        "local function d(a, b)\n  return a // b\nend\nd(1, 1)\nd(2, 1)\nreturn d(1, 0)",
        "local function m(a, b)\n  return a %\n    b\nend\nm(1, 1)\nreturn m(1, 0)",
        "local function d(a, b) return a // b end d(1.0, 1) return d(1.0, 0), d(1, 0.0)",
        "local function f(n) local s = 0 for i = 1, n do s = s + 10 // (3 - i) end return s end return pcall(f, 2), pcall(f, 3), pcall(f, 4)",
        // loops: bounds of every kind
        "local function f(a, b, c) local n = 0 for i = a, b, c do n = n + 1 end return n end return f(1, 10, 1), f(10, 1, -1), f(1, 3.5, 1), f(1, 0, 1), f(math.maxinteger - 2, math.maxinteger, 1), f(1, 2, 0.25), f(1, math.huge, math.maxinteger)",
        "local function f(a, b, c) local n = 0 for i = a, b, c do n = n + 1 end return n end return pcall(f, 1, 10, 0), pcall(f, 1.0, 10, 0)",
        "local function f(n) local x = 0.0 for i = 1, n do x = x + i / 2 end return x end return f(0), f(1), f(10), f(100000)",
        // comparisons between integers and floats
        "local function lt(a, b) return a < b end local function le(a, b) return a <= b end return lt(1, 1.5), lt(2^53, 2^53 + 1), lt(9007199254740993, 9007199254740992.0), le(math.maxinteger, 2^63), lt(math.mininteger, -2^63), lt(0/0, 1), le(1, 0/0)",
        "local function e(a, b) return a == b end return e(1, 1.0), e(2^53, 2^53 + 1), e(math.maxinteger, math.maxinteger + 0.0), e(0/0, 0/0), e(true, true)",
        // no parameters; a function without a result called as a statement; a boolean global
        "local function k() return 42 end local function k2() local s = 0 for i = 1, 10 do s = s + i end return s end return k(), k2(), k() + k2()",
        "local function v(n) local s = 0 for i = 1, n do s = s + i end end local function w(n) v(n) v(n + 1) return n end return w(3), w(4.5), w(0)",
        "ok = true local function f(x) if ok then return x end return -x end local a, b = f(1), f(2) ok = false local c = f(3) ok = 0 return a, b, c, pcall(f, 4)",
        // the same variable twice on the left: the interpreter stores right to left, so the first value wins
        "local function f(a, b) local x = 0 x, x = a, b return x end local function g(a, b, c) local x, y = 0, 0 x, y, x = a, b, c return x * 100 + y end "
        "return f(1, 2), f(1.5, 2.5), g(1, 2, 3), g(1.5, 2.5, 3.5)",
        // every comparison of integers around 2^53 and 2^63 with floats, in both orders
        "local function lt(a, b) return a < b end local function le(a, b) return a <= b end local function gt(a, b) return a > b end "
        "local function ge(a, b) return a >= b end local function eq(a, b) return a == b end local function ne(a, b) return a ~= b end "
        "local ints = {0, 1, -1, 9007199254740991, 9007199254740992, 9007199254740993, 9007199254740995, 4611686018427387904, 9223372036854775807, "
        "-9223372036854775807 - 1, -9007199254740993, -9007199254740992} "
        "local flts = {0.0, 0.5, -0.5, 1.0, 9007199254740992.0, 9007199254740994.0, 9223372036854775808.0, -9223372036854775808.0, 1e300, -1e300, 1/0, -1/0} "
        "local out = {} local function t(b) out[#out + 1] = b and 'T' or 'F' end "
        "for i = 1, #ints do for j = 1, #flts do local a, b = ints[i], flts[j] "
        "t(lt(a, b)) t(le(a, b)) t(gt(a, b)) t(ge(a, b)) t(eq(a, b)) t(ne(a, b)) t(lt(b, a)) t(le(b, a)) t(gt(b, a)) t(ge(b, a)) t(eq(b, a)) t(ne(b, a)) end end "
        "return table.concat(out)",
        // shifts and bits
        "local function s(x, n) return x << n, x >> n end local function l(x, n) return x << n end local function r(x, n) return x >> n end return l(1, 63), l(1, 64), l(1, -1), r(-1, 1), r(-1, 64), l(1.0, 2), pcall(l, 1.5, 1)",
        // booleans, and/or/not
        "local function f(a, b, c) if a < b and b < c or a == c then return 1 elseif not (a < c) then return 2 end return 3 end return f(1, 2, 3), f(3, 2, 1), f(1, 3, 2), f(2, 2, 2), f(1.5, 2, 3)",
        "local function f(x) return x > 0 and x < 10 end return f(5), f(-1), f(50), f(5.5)",
        // wrong arguments, a result and a variable of either kind, and a shape that is not a kernel
        "local function f(n) if n < 2 then return n end return f(n - 1) + f(n - 2) end return pcall(f), pcall(f, 'x'), pcall(f, {}), f(10), f(10.0)",
        "local function f(n) local x = 0 for i = 1, n do x = x + 0.5 end return x end return f(3), f(0)",
        "local function f(n) if n > 0 then return n end return 0.5 end return f(1), f(0), math.type(f(1)), math.type(f(0))",
        "local function f(n) return n, n end return f(1)",
        // deep recursion, at and beyond the interpreter's limit
        "local function d(n) if n == 0 then return 0 end return 1 + d(n - 1) end return d(10), d(1000), pcall(d, 100000)",
        "local function d(n) if n == 0 then return 0 end return 1 + d(n - 1) end local r = {} for n = 1490, 1505 do r[#r + 1] = tostring(select(2, pcall(d, n))) end return table.concat(r, ' ')",
        "local function d(n) if n == 0 then return 0 end return 1 + d(n - 1) end return d(1400)",
        "local function a(n) if n == 0 then return 0 end return 1 + b(n - 1) end function b(n) if n == 0 then return 0 end return 1 + a(n - 1) end return a(100), pcall(a, 5000)",
        // a NaN made from constants prints the same (its sign is the processor's, not the C compiler's)
        "local function n0() return 0.0 / 0.0 end local function n1(a) local z = 0.0 return a / z - a / z end local function n2() local z = 0.0 return z / z end "
        "local function n3() return 1e308 * 10 - 1e308 * 10 end return n0(), n1(1.0), n2(), n3(), n0() ~= n0()",
        // numbers that are an integer or a float as the run goes: accumulators, results, parameters, calls, bitwise operators, comparisons
        "local function sum(n, x) local s = 0 for i = 1, n do s = s + x end return s end return sum(10, 0.5), sum(10, 2), sum(0, 0.5), sum(3, 1.5), math.type(sum(0, 0.5)), math.type(sum(2, 0.5)), math.type(sum(2, 2))",
        "local function mix(a, b) local r = a if b > 2 then r = r * 1.5 end return r end return mix(3, 1), mix(3, 5), mix(4.5, 5), mix(4.5, 1), math.type(mix(4, 1))",
        "local function collatz(n) local steps = 0 while n ~= 1 do if n % 2 == 0 then n = n // 2 else n = 3 * n + 1 end steps = steps + 1 end return steps end return collatz(27), collatz(97)",
        "local function area(n) local acc = 0 for i = 1, n do acc = acc + i / 2 if acc > 100 then acc = acc // 3 end end return acc end return area(10), area(50), area(0), math.type(area(0))",
        "local function bits(a, b, k) local x = a if b > 0 then x = x + 0.0 end if k == 1 then return x & 7 end if k == 2 then return ~x end if k == 3 then return x << 2 end return x | b end "
        "local r = {} for k = 1, 4 do r[#r + 1] = tostring(bits(5, 0, k)) .. ' ' .. tostring(bits(5, 1, k)) .. ' ' .. tostring(bits(-3, 2, k)) .. ' ' .. tostring(select(2, pcall(bits, 5.5, 1, k))) end return table.concat(r, ';')",
        "local function half(a, b) local x = 1 if b > 0 then x = a / 2 end return x & 1 end return half(5, 0), half(4, 1), pcall(half, 5, 1)",
        "local function divn(a, b, k) local x = a if b > 100 then x = x + 0.5 end if k == 1 then return x // b end return x % b end "
        "return divn(7, 2, 1), pcall(divn, 7, 0, 1), divn(7, 200, 1), divn(-7, 0.0, 1), divn(math.mininteger, -1, 1), divn(7, 2, 2), pcall(divn, 7, 0, 2), divn(7, 200, 2), divn(math.mininteger, -1, 2), divn(-7, 0.0, 2) ~= divn(-7, 0.0, 2)",
        "local function cmpn(a, b, k) local x = a if b then x = 2^53 end if k == 1 then return x < 9007199254740993 end if k == 2 then return x == 9007199254740992 end "
        "if k == 3 then return x >= 9007199254740993 end if k == 4 then return 9007199254740993 > x end return x ~= 3 end "
        "local r = {} for k = 1, 5 do r[#r + 1] = tostring(cmpn(1, false, k)) .. tostring(cmpn(1, true, k)) .. tostring(cmpn(9007199254740993, true, k)) .. tostring(cmpn(9007199254740993, false, k)) end return table.concat(r, ' ')",
        "local function lim(n, k) local m = n if k then m = n + 0.5 end local c = 0 for i = 1, m do c = c + i end return c end return lim(3, false), lim(3, true), lim(0, true), lim(1, false)",
        "local function lv(n) local t = 0 for i = 1, n do if i == 2 then i = i + 0.5 end t = t + i end return t end return lv(3), lv(1), lv(0)",
        "local function f2(x) if x > 5 then return x * 0.5 end return x end local function g2(x) local t = f2(x) + f2(x + 5) return t end return g2(1), g2(2.5), g2(10), f2(2), f2(6), math.type(g2(1))",
        "local function rec(n, acc) if n == 0 then return acc end if n % 3 == 0 then return rec(n - 1, acc + 0.25) end return rec(n - 1, acc + 1) end return rec(10, 0), rec(9, 0), rec(0, 5), rec(3, 1.0), math.type(rec(0, 5)), math.type(rec(1, 5))",
        "function ev(n, a) if n == 0 then return a end return od(n - 1, a + 1) end function od(n, a) if n == 0 then return a * 2 end return ev(n - 1, a + 0.5) end return ev(5, 0), ev(4, 1), od(3, 0), ev(0, 7), od(0, 7), math.type(ev(0, 7)), math.type(ev(1, 7))",
        "local function h(a) return a & 3 end local function g(c) local x = 2.0 local r = h(x) if c then x = 3 end return h(x) + r end return g(true), g(false)",
        "local function negz(n) local s = 0 for i = 1, n do s = s - 0.0 end return -s end return negz(3), negz(0), math.type(negz(0))",
        "local function ao(a, b) local x = a if b then x = x + 0.5 end return (x and 7) + (x or 9) end return ao(1, false), ao(1, true)",
        "local function sw(a, b) local x, y = a, b if a < b then x, y = y + 0.5, x end return x * 10 + y end return sw(1, 2), sw(2, 1), sw(1.5, 2)",
        "local function dd(a, b, c) local x = a local y = b if c then x = 1.5 y = 0 end return x // y end return dd(7, 2, false), pcall(dd, 7, 0, false), dd(7, 2, true), pcall(dd, 7, 0, true)",
        "local function t1(a, b) local x = a if b then x = 0.5 end return -x end local function t2(a, b) local x = a if b then x = 0.5 end return x ^ 2 end local function t3(a, b) local x = a if b then x = 0.5 end return x // 1 end "
        "return t1(3, false), t1(3, true), t2(3, false), t2(3, true), t3(3, false), t3(3, true), t3(-3, true)",
        "local function big(a, b) local x = a if b then x = x + 0.0 end return x == a end local function big2(a, b) local x = a if b then x = x + 0.0 end return x < a + 1 end "
        "return big(9007199254740993, false), big(9007199254740993, true), big(math.maxinteger, true), big2(9007199254740993, true), big2(9007199254740993, false), big2(math.maxinteger, true)",
        // every comparison between integers and floats around 2^53 and 2^63 when both operands are numbers of either kind (an integer in
        // one, a float in the other, as the run goes), in both orders
        "local function ca(a, b, c) local x, y = a, b if c then x = x + 0.5 y = 0 end local r = 0 "
        "if x < y then r = r + 1 end if x <= y then r = r + 2 end if x > y then r = r + 4 end if x >= y then r = r + 8 end "
        "if x == y then r = r + 16 end if x ~= y then r = r + 32 end return r end "
        "local function cb(a, b, c) local x, y = a, b if c then x = 0 y = y + 0.5 end local r = 0 "
        "if x < y then r = r + 1 end if x <= y then r = r + 2 end if x > y then r = r + 4 end if x >= y then r = r + 8 end "
        "if x == y then r = r + 16 end if x ~= y then r = r + 32 end return r end "
        "local ints = {0, 1, -1, 9007199254740991, 9007199254740992, 9007199254740993, 9007199254740995, 4611686018427387904, 9223372036854775807, "
        "-9223372036854775807 - 1, -9007199254740993, -9007199254740992} "
        "local flts = {0.0, 0.5, -0.5, 1.0, 9007199254740992.0, 9007199254740994.0, 9223372036854775808.0, -9223372036854775808.0, 1e300, -1e300, 1/0, -1/0, 0/0} "
        "local out = {} for i = 1, #ints do for j = 1, #flts do out[#out + 1] = ca(ints[i], flts[j], false) out[#out + 1] = cb(flts[j], ints[i], false) "
        "out[#out + 1] = ca(ints[i], ints[j] or 0, false) out[#out + 1] = ca(flts[j], flts[i] or 0.5, false) end end return table.concat(out, ',')",
        // floats: the mandelbrot iteration and integration
        "local function m(cx, cy, k) local x, y, i = 0.0, 0.0, 0 while i < k and x * x + y * y <= 4.0 do x, y = x * x - y * y + cx, 2.0 * x * y + cy i = i + 1 end return i end return m(0, 0, 20), m(1, 1, 20), m(-0.75, 0.1, 100), m(0.3, 0.5, 100)",
        "local s = 0.5 local function f(x) return s * x * x end local function g(n) local t = 0.0 for i = 1, n do t = t + f(i) end return t end return g(10), g(100)",
    };
    for (const char* p : progs) same(plain, tiered, p, p);
    CHECK(tiered.stats.tier_calls > 20);
    CHECK(tiered.stats.tier_aborts >= 4);                  // the errors above were found by running the compiled code first
    CHECK(consistent(plain) && consistent(tiered));
    // the tier did not change what the interpreter did on its own: no stray state in the two Statess
    CHECK(eval(plain, "return 1 + 1") == "2" && eval(tiered, "return 1 + 1") == "2");
  }

  std::printf("-- the error texts and positions\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    CHECK(eval(S, "local function d(a, b)\n  return a // b\nend\nd(1, 1)\nreturn d(1, 0)") == "ERR:test:2: attempt to divide by zero");
    CHECK(S.stats.tier_aborts == 1);
    CHECK(consistent(S));
    CHECK(eval(S, "local function m(a, b)\n  return\n    a % b\nend\nm(1, 1)\nreturn m(1, 0)") == "ERR:test:3: attempt to perform 'n%0'");
    CHECK(eval(S, "local function f(a, b, c) local n = 0 for i = a, b, c do n = n + 1 end return n end f(1, 2, 1) return f(1, 5, 0)") ==
          "ERR:test:1: 'for' step is zero");
    CHECK(consistent(S));
    // a traceback names the frames of the interpreter's re-run
    std::string err;
    nfcast::Closure* cl = S.load("local function inner(a, b) return a // b end\nlocal function outer(a, b) return inner(a, b) end\nouter(1, 1)\nouter(1, 0)", "test", &err);
    Rets out;
    std::size_t depth = 0;
    try {
      S.call(Value::function(cl), nullptr, 0, out);
    } catch (Thrown& t) {
      depth = t.trace.size();
    }
    CHECK(depth == 3);                                       // inner, outer, main chunk
    CHECK(consistent(S));
  }

  std::printf("-- loops count towards the threshold; a function that is not a kernel is left alone\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 100, cache);
    CHECK(eval(S, "function work(n) local s = 0 for i = 1, n do s = s + i end return s end return work(10000)") == "50005000");
    CHECK(S.stats.tier_compiled == 1 && S.stats.tier_calls == 0);   // compiled during that call, which went on in the interpreter
    CHECK(eval(S, "return work(10)") == "55");
    CHECK(S.stats.tier_calls == 1);                                // the next call uses it
    CHECK(eval(S, "function t1(n) local t = {} for i = 1, n do t[i] = i end return #t end for i = 1, 200 do t1(3) end return t1(5)") == "5");
    CHECK(S.stats.tier_ineligible == 1);                            // counted once, however often it is looked at
    CHECK(eval(S, "function t2(n) local s = 0 for i = 1, n do s = s + 1 end print = print return s end for i = 1, 300 do t2(1) end return t2(2)") == "2");
    CHECK(S.stats.tier_ineligible == 2);
    nfcast::Closure* cl = S.load("return t1, work", "test", nullptr);
    Rets o;
    S.call(Value::function(cl), nullptr, 0, o);
    CHECK(S.tier_state(o.p[0]).find("ineligible") != std::string::npos);
    CHECK(S.tier_state(o.p[1]).find("compiled i->i") != std::string::npos);
    CHECK(consistent(S));
  }

  std::printf("-- signatures, versions, and a function that keeps failing\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    eval(S, "function id(x) return x end");
    CHECK(eval(S, "return id(1), id(1.5), id(true), id(2), id(2.5)") == "1,1.5,true,2,2.5");
    CHECK(S.stats.tier_compiled == 3 && S.stats.tier_calls == 5);
    // a kernel that divides by a variable that is zero every time: the compiled code is abandoned each time, then given up on
    eval(S, "function z(a, b) return a // b end");
    for (int i = 0; i < 40; ++i) eval(S, "pcall(z, 1, 0)");
    CHECK(S.stats.tier_aborts >= 8 && S.stats.tier_aborts < 40);   // after enough failures it stops trying
    nfcast::Closure* cl = S.load("return z", "test", nullptr);
    Rets o;
    S.call(Value::function(cl), nullptr, 0, o);
    CHECK(S.tier_state(o.first()).find("abandoned") != std::string::npos);
    CHECK(eval(S, "return z(7, 2)") == "3");                        // still correct
    CHECK(consistent(S));
  }

  std::printf("-- at most four versions of a function; operands that can fail keep their order\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, cache);
    eval(S, "function two(a, b) return a + b end");
    CHECK(eval(S, "return two(1, 2), two(1, 2.5), two(1.5, 2), two(1.5, 2.5)") == "3,3.5,3.5,4.0");
    CHECK(S.stats.tier_compiled == 4 && S.stats.tier_calls == 4);
    CHECK(eval(S, "return two(true, 1)") == "ERR:test:1: attempt to perform arithmetic on a boolean value (local 'a')");
    CHECK(S.stats.tier_compiled == 4 && S.stats.tier_calls == 4 && S.stats.tier_bailouts == 1);   // a fifth combination: no version for it
    CHECK(eval(S, "return two(5, 6)") == "11");
    CHECK(S.stats.tier_calls == 5);
    // `(1 // a) + spin(0)`: the interpreter divides first and raises; the C compiler may evaluate the operands of + in either order,
    // and spin never returns. The generated code must raise (this check would hang otherwise: the alarm ends the test)
    alarm(120);
    eval(S, "local function spin(n) while true do n = n + 1 end return n end function g(a) return (1 // a) + spin(0) end");
    CHECK(eval(S, "return pcall(g, 0)") == "false,test:1: attempt to divide by zero");
    // the same with the arguments of a call, which C compilers often evaluate from the right
    eval(S, "local function spin2(n) while true do n = n + 1 end return n end local function add(x, y) return x + y end "
            "function g2(a) return add(1 // a, spin2(0)) end");
    CHECK(eval(S, "return pcall(g2, 0)") == "false,test:1: attempt to divide by zero");
    alarm(0);
    CHECK(consistent(S));
  }

  std::printf("-- a collector that runs at every safe point\n");
  {
    State S;
    S.open_libs();
    S.gc_stress = true;
    tier_on(S, TierOptions::Sync, 1, cache);
    CHECK(eval(S, "local function f(n) if n < 2 then return n end return f(n - 1) + f(n - 2) end local t = {} for i = 1, 20 do t[i] = f(i) end return t[20], #t") == "6765,20");
    CHECK(S.stats.tier_calls > 0);
    CHECK(consistent(S));
  }

  std::printf("-- the compiled code is cached on disk and found by a second State\n");
  {
    std::string c2 = temp_dir("cache2");
    const char* prog = "local function f(a, b) return (a + b) * (a - b) end return f(7, 3), f(10, 1)";
    {
      State A;
      A.open_libs();
      tier_on(A, TierOptions::Sync, 1, c2);
      CHECK(eval(A, prog) == "40,99");
      CHECK(A.stats.tier_compiles == 1 && A.stats.tier_cache_hits == 0 && A.stats.tier_compiled == 1);
    }
    {
      State B;
      B.open_libs();
      tier_on(B, TierOptions::Sync, 1, c2);
      CHECK(eval(B, prog) == "40,99");
      CHECK(B.stats.tier_compiles == 0 && B.stats.tier_cache_hits == 1 && B.stats.tier_compiled == 1);
      CHECK(B.stats.tier_calls == 2);
    }
  }

  std::printf("-- a compile that fails leaves the interpreter working\n");
  {
    std::string c3 = temp_dir("cache3");
    const char* prog = "local function f(n) if n < 2 then return n end return f(n - 1) + f(n - 2) end return f(15), f(16)";
    {
      State S;  // no such driver
      S.open_libs();
      tier_on(S, TierOptions::Sync, 1, c3, "/nonexistent/dir/nfcxx");
      CHECK(eval(S, prog) == "610,987");
      CHECK(S.stats.tier_failed >= 1 && S.stats.tier_compiled == 0 && S.stats.tier_calls == 0);
      nfcast::Closure* cl = S.load("return 1", "test", nullptr);
      CHECK(cl != nullptr);
      CHECK(consistent(S));
    }
    {
      State S;  // a driver that fails
      S.open_libs();
      tier_on(S, TierOptions::Sync, 1, c3, "/bin/false");
      CHECK(eval(S, prog) == "610,987");
      CHECK(S.stats.tier_failed >= 1 && S.stats.tier_compiled == 0);
      CHECK(eval(S, "return f_does_not_exist") == "nil");
    }
    {
      State S;  // a driver that exits 0 and makes nothing
      S.open_libs();
      tier_on(S, TierOptions::Sync, 1, c3, "/bin/true");
      CHECK(eval(S, prog) == "610,987");
      CHECK(S.stats.tier_failed >= 1 && S.stats.tier_compiled == 0);
    }
    {
      State S;  // a damaged entry in the cache is replaced
      S.open_libs();
      tier_on(S, TierOptions::Sync, 1, c3);
      CHECK(eval(S, prog) == "610,987");
      CHECK(S.stats.tier_compiled == 1);
      std::string cmd = "for f in '" + c3 + "'/nfcast-tier-*.so; do rm -f \"$f\"; echo damaged > \"$f\"; done";  // new files: S still maps the old ones
      int rc = std::system(cmd.c_str());
      CHECK(rc == 0);
      State T;
      T.open_libs();
      tier_on(T, TierOptions::Sync, 1, c3);
      CHECK(eval(T, prog) == "610,987");
      CHECK(T.stats.tier_compiled == 1 && T.stats.tier_calls >= 1);
    }
  }

  std::printf("-- asynchronous compiles\n");
  {
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Async, 1, cache);
    eval(S, "function afib(n) if n < 2 then return n end return afib(n - 1) + afib(n - 2) end");
    CHECK(eval(S, "return afib(18)") == "2584");              // runs in the interpreter while the compile goes on
    S.tier_wait();
    std::uint64_t calls = S.stats.tier_calls;
    CHECK(S.stats.tier_compiled == 1);
    CHECK(eval(S, "return afib(20)") == "6765");
    CHECK(S.stats.tier_calls == calls + 1);
    CHECK(consistent(S));
    // more compiles than jobs: the others wait their turn, and every function ends up compiled
    {
      State Q;
      Q.open_libs();
      TierOptions o;
      o.mode = TierOptions::Async;
      o.threshold = 1;
      o.jobs = 1;
      o.cache_dir = temp_dir("cache7");
      Q.enable_tier(o);
      CHECK(eval(Q, "local function a(x) return x + 1 end local function b(x) return x * 2 end local function c(x) return x - 3 end return a(1), b(2), c(3)") == "2,4,0");
      Q.tier_wait();
      CHECK(Q.stats.tier_compiled == 3 && Q.stats.tier_failed == 0 && Q.stats.tier_compiles == 3);
      CHECK(eval(Q, "local function a(x) return x + 1 end local function b(x) return x * 2 end local function c(x) return x - 3 end return a(1), b(2), c(3)") == "2,4,0");
    }
    // a State that goes away with a compile still running does not wait for it or leave it behind
    {
      State T;
      T.open_libs();
      tier_on(T, TierOptions::Async, 1, temp_dir("cache4"));
      CHECK(eval(T, "local function g(n) return n * n + 1 end return g(3), g(4)") == "10,17");
    }
  }

  std::printf("-- a host that ignores SIGCHLD\n");
  {
    void (*old)(int) = signal(SIGCHLD, SIG_IGN);   // the compiler's child is reaped by the system: its status is never seen
    State S;
    S.open_libs();
    tier_on(S, TierOptions::Sync, 1, temp_dir("cache5"));
    CHECK(eval(S, "local function f(a, b) return a * b - a end return f(3, 4), f(5, 6)") == "9,25");
    CHECK(S.stats.tier_compiled == 1 && S.stats.tier_calls == 2 && S.stats.tier_failed == 0);
    State T;
    T.open_libs();
    tier_on(T, TierOptions::Async, 1, temp_dir("cache6"));
    CHECK(eval(T, "local function f(a, b) return a * b - a end return f(3, 4), f(5, 6)") == "9,25");
    T.tier_wait();
    CHECK(T.stats.tier_compiled == 1 && T.stats.tier_failed == 0);
    signal(SIGCHLD, old);
  }

  std::printf("-- environment\n");
  {
    State S;
    S.open_libs();
    TierOptions o;
    o.mode = TierOptions::Off;
    S.enable_tier(o);
    CHECK(S.tier == nullptr);
    CHECK(eval(S, "return 1") == "1");
  }

  remove_dirs();
  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
