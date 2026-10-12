// Engine-level checks of nfcast that need the C++ API: the nodes specialize (and give way when their guard fails), the
// collector frees what is unreachable and keeps what is pinned or referenced, host objects, error values and the state of
// the interpreter after errors. Exit status 0 when every check passes. Run by tests/ast/run.sh.
#include <cstdio>
#include <string>
#include <tuple>
#include <vector>

#include "nfcast.hpp"

using nfcast::Args;
using nfcast::Rets;
using nfcast::State;
using nfcast::Thrown;
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

// Runs CODE as a chunk; returns its first result (nil if it has none). Sets *err to the error text when it fails.
static Value run(State& S, const std::string& code, std::string* err = nullptr) {
  std::string e;
  nfcast::Closure* cl = S.load(code, "test", &e);
  if (!cl) {
    if (err) *err = e;
    return Value();
  }
  Rets out;
  try {
    S.call(Value::function(cl), nullptr, 0, out);
  } catch (Thrown& t) {
    if (err) *err = S.tostring(t.v);
    return Value();
  }
  if (err) err->clear();
  return out.first();
}

static std::int64_t run_int(State& S, const std::string& code) {
  Value v = run(S, code);
  return v.t == nfcast::T_INT ? v.i : -999999;
}

// A host object that counts how many are alive. `id` is a read-only field; any other name is a method that returns how many
// arguments it got.
struct Probe : nfcast::HostObject {
  static int live;
  int id;
  struct Field : nfcast::HostMember {
    Value get(State&, nfcast::HostObject* self) override { return Value::integer(static_cast<Probe*>(self)->id); }
    void set(State& S, nfcast::HostObject*, const Value&) override { S.rt_error("read-only"); }
    void call(State& S, nfcast::HostObject*, Args, Rets&) override { S.rt_error("not a method"); }
  };
  struct Method : nfcast::HostMember {
    Method() { is_method = true; }
    Value get(State&, nfcast::HostObject*) override { return Value(); }
    void set(State& S, nfcast::HostObject*, const Value&) override { S.rt_error("cannot assign to a method"); }
    void call(State&, nfcast::HostObject*, Args a, Rets& r) override { r.push(Value::integer(a.n)); }
  };
  explicit Probe(int i) : id(i) { ++live; }
  ~Probe() override { --live; }
  const void* type_key() const override { return &key; }
  nfcast::HostMember* member(State&, nfcast::String* name) override {
    static Field field;
    static Method method;
    if (name->view() == "id") return &field;
    return &method;
  }
  static const char key;
};
int Probe::live = 0;
const char Probe::key = 0;

// cb(f, args...): the host calls f from inside the script, the way a bound function that takes a callback does.
static void native_cb(State& S, Args a, Rets& r, nfcast::Native&) {
  Rets out;
  S.call(a[0], a.v + 1, a.n > 0 ? a.n - 1 : 0, out);
  for (int i = 0; i < out.n; ++i) r.push(out.p[i]);
}

static void native_make_probe(State& S, Args a, Rets& r, nfcast::Native&) {
  r.push(Value::host(S.new_host<Probe>(a.n ? static_cast<int>(a.v[0].i) : 0)));
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  State S;
  S.open_libs();
  S.globals->set_str(S, S.str("make_probe"), Value::function(S.new_native(native_make_probe, "make_probe")));

  std::printf("-- specialization\n");
  {
    auto st0 = S.stats;
    CHECK(run_int(S, "local s = 0 for i = 1, 1000 do s = s + i * 2 - 1 end return s") == 1000000);
    CHECK(S.stats.rewrites >= st0.rewrites + 3);         // + * - each replaced itself by an integer node
    CHECK(S.stats.generic_ops == st0.generic_ops);       // nothing took a slow path
    CHECK(S.stats.deopts == st0.deopts);
    run(S, "function add(a, b) return a + b end");
    auto st1 = S.stats;
    CHECK(run_int(S, "return add(1, 2)") == 3);
    CHECK(run_int(S, "return add(3, 4)") == 7);
    CHECK(S.stats.deopts == st1.deopts);                 // integers again: same node
    Value f = run(S, "return add(1.5, 2)");              // a float reaches the integer node: guard fails, one rewrite
    CHECK(f.t == nfcast::T_FLT && f.d == 3.5);
    CHECK(S.stats.deopts == st1.deopts + 1);
    auto st2 = S.stats;
    f = run(S, "return add(2.5, 4)");                    // now a number node: no slow path, no deopt
    CHECK(f.t == nfcast::T_FLT && f.d == 6.5);
    CHECK(S.stats.generic_ops == st2.generic_ops && S.stats.deopts == st2.deopts);
    Value str = run(S, "return add('10', 5)");           // strings fall back to the generic node
    CHECK(str.t == nfcast::T_INT && str.i == 15);
    CHECK(S.stats.generic_ops > st2.generic_ops);
    // fields of a table: an inline cache, no slow path
    run(S, "obj = {x = 1, y = 2, z = 3}");
    auto st3 = S.stats;
    CHECK(run_int(S, "local s = 0 for i = 1, 500 do s = s + obj.x + obj.y + obj.z end return s") == 3000);
    CHECK(S.stats.generic_ops == st3.generic_ops);
    CHECK(run_int(S, "local t = {} for i = 1, 100 do t[i] = i end local s = 0 for i = 1, #t do s = s + t[i] end return s") == 5050);
    CHECK(S.stats.generic_ops == st3.generic_ops);       // the array part: no slow path either
    // a method call on a table with a metatable index goes through the generic path, and still works
    CHECK(run_int(S, "local C = {} C.__index = C function C:get() return self.v end local o = setmetatable({v = 9}, C) return o:get() + o:get()") == 18);
    // calls: a closure, a native, a host method keep their kinds
    CHECK(run_int(S, "local function f(x) return x + 1 end local s = 0 for i = 1, 100 do s = s + f(i) + #tostring(i) end return s") == 5050 + 100 + 9 + 180 + 3);
    // the same node sees different types over time and stays correct
    CHECK(run_int(S, "local function g(x) return x.n end local a, b = {n = 1}, setmetatable({}, {__index = {n = 20}}) return g(a) + g(b) + g(a)") == 22);
  }

  std::printf("-- the collector\n");
  {
    S.collect();
    std::size_t base = S.gc_bytes();
    run(S, "for i = 1, 20000 do local t = {i, {i}, tostring(i)} end");
    S.collect();
    CHECK(S.gc_bytes() <= base + 4096);                  // everything the loop made is gone
    run(S, "keep = {} for i = 1, 100 do keep[i] = {i, 'x' .. i} end");
    S.collect();
    CHECK(S.gc_bytes() > base + 4096);
    CHECK(run_int(S, "local s = 0 for i = 1, #keep do s = s + keep[i][1] + #keep[i][2] end return s") == 5050 + 100 + 9 + 180 + 3);
    run(S, "keep = nil");
    S.collect();
    CHECK(S.gc_bytes() <= base + 4096);
    // pins keep a value alive and unpin releases it
    Value t = run(S, "return {a = 1}");
    int pin = S.pin(t);
    run(S, "local junk = {} for i = 1, 100 do junk[i] = {} end");
    S.collect();
    Value p = S.pinned(pin);
    CHECK(p.t == nfcast::T_TAB && p.tab()->get_str(S.str("a")).i == 1);
    S.unpin(pin);
    // a string held only by a function's constants survives
    run(S, "function name_of() return 'a-constant-string-that-lives-in-the-function' end");
    S.collect();
    S.collect();
    Value nm = run(S, "return name_of()");
    CHECK(nm.t == nfcast::T_STR && nm.s()->view() == "a-constant-string-that-lives-in-the-function");
    // constants of a nested function are kept while the outer function exists, though no inner closure does
    run(S, "function outer() return function() return 'inner-constant-xyz' end end");
    S.collect();
    CHECK(run(S, "return outer()()").s()->view() == "inner-constant-xyz");
  }

  std::printf("-- host objects\n");
  {
    S.collect();
    int base = Probe::live;
    run(S, "for i = 1, 100 do make_probe(i) end");
    CHECK(Probe::live == base + 100);                    // not collected yet
    S.collect();
    CHECK(Probe::live == base);
    run(S, "held = make_probe(7)");
    S.collect();
    CHECK(Probe::live == base + 1);
    CHECK(run_int(S, "return held.id") == 7);
    CHECK(run_int(S, "return held:anything(1, 2, 3)") == 3);
    run(S, "held = nil");
    S.collect();
    CHECK(Probe::live == base);
    std::string err;
    run(S, "local p = make_probe(1) p.id = 5", &err);
    CHECK(err.find("read-only") != std::string::npos);
    CHECK(run(S, "return make_probe(3) == make_probe(3)").t == nfcast::T_FALSE);   // different objects
    // objects still referenced when the State goes away are deleted
  }

  std::printf("-- errors\n");
  {
    std::string err;
    run(S, "error('boom')", &err);
    CHECK(err == "test:1: boom");
    run(S, "local t = nil return t.x", &err);
    CHECK(err == "test:1: attempt to index a nil value (local 't')");
    run(S, "return 1 +", &err);
    CHECK(err.find("test:1:") == 0 && err.find("near <eof>") != std::string::npos);
    run(S, "x = = 1", &err);
    CHECK(err.find("unexpected symbol near '='") != std::string::npos);
    run(S, "for i = 1, 2 do", &err);
    CHECK(err.find("'end' expected near <eof>") != std::string::npos);
    run(S, "if x then\n\nreturn 1", &err);
    CHECK(err.find("'end' expected (to close 'if' at line 1) near <eof>") != std::string::npos);
    run(S, "local s = 'unfinished", &err);
    CHECK(err.find("unfinished string") != std::string::npos);
    run(S, "return 0x", &err);
    CHECK(err.find("malformed number") != std::string::npos);
    run(S, "local x <const> = 1; x = 2", &err);
    CHECK(err.find("attempt to assign to const variable 'x'") != std::string::npos);
    // a table error value travels as itself, with a traceback only when nothing catches it
    nfcast::Closure* cl = S.load("local function f() error({code = 9}) end f()", "test", &err);
    Rets out;
    bool got = false;
    try {
      S.call(Value::function(cl), nullptr, 0, out);
    } catch (Thrown& t) {
      got = t.v.t == nfcast::T_TAB && t.v.tab()->get_str(S.str("code")).i == 9 && t.trace.size() == 2;
    }
    CHECK(got);
    cl = S.load("return pcall(error, {})", "test", &err);
    Rets out2;
    S.call(Value::function(cl), nullptr, 0, out2);
    CHECK(out2.n == 2 && out2.p[0].t == nfcast::T_FALSE);   // caught inside: pcall returns it
    // the interpreter is consistent after errors: depth, stack top and the pcall counter are back
    CHECK(S.depth == 0 && S.top == S.stack && S.pcall_depth == 0 && S.cur == nullptr);
    // a stack overflow is an error value, not a crash, and leaves the state usable
    run(S, "local function f() return 1 + f() end return f()", &err);
    CHECK(err.find("stack overflow") != std::string::npos);
    CHECK(S.depth == 0 && S.top == S.stack);
    CHECK(run_int(S, "return 1 + 1") == 2);
    // a deep but legal recursion
    CHECK(run_int(S, "local function d(n) if n == 0 then return 0 end return 1 + d(n - 1) end return d(1000)") == 1000);
    // errors inside metamethods and callbacks
    run(S, "local t = setmetatable({}, {__index = function() error('in index') end}) return t.x", &err);
    CHECK(err == "test:1: in index");
    run(S, "table.sort({3, 2, 1}, function(a, b) error('cmp') end)", &err);
    CHECK(err == "test:1: cmp");
    CHECK(S.depth == 0 && S.top == S.stack);
    // the position of an error raised by a native function: the calling line, or none when pcall is the caller
    run(S, "\n\nstring.rep()", &err);
    CHECK(err == "test:3: bad argument #1 to 'rep' (string expected, got no value)");
    CHECK(run(S, "return select(2, pcall(string.rep))").s()->view() == "bad argument #1 to 'string.rep' (string expected, got no value)");
    // an error caught by pcall leaves no trace in how the next native call is reported: position and call-site name are back
    run(S, "pcall(string.rep)\nstring.rep()", &err);
    CHECK(err == "test:2: bad argument #1 to 'rep' (string expected, got no value)");
    run(S, "pcall(function() string.rep() end)\nlocal s = ('x'):rep({})", &err);
    CHECK(err == "test:2: bad argument #1 to 'rep' (number expected, got table)");   // `obj:m()` does not count the object
  }

  std::printf("-- strings and tables\n");
  {
    nfcast::String* a = S.str("short");
    nfcast::String* b = S.str(std::string("sh") + "ort");
    CHECK(a == b);                                        // short strings are interned
    std::string longs(100, 'x');
    nfcast::String* c = S.str(longs);
    nfcast::String* d = S.str(longs);
    CHECK(c != d);                                        // long ones are not, but they compare equal as keys
    nfcast::Table* t = S.new_table();
    t->set_str(S, c, Value::integer(1));
    CHECK(t->get_str(d).i == 1);
    CHECK(S.str(std::string("a\0b", 3))->len == 3);       // embedded zeros
    CHECK(run_int(S, "return #'a\\0b'") == 3);
    CHECK(run_int(S, "local t = {} t[1.0] = 'a' t[2^53] = 'b' return #t + (t[1] == 'a' and 10 or 0)") == 11);
    CHECK(run_int(S, "local t = {1, 2, 3} t[#t + 1] = 4 t[#t + 1] = 5 return #t") == 5);
    CHECK(run_int(S, "local t = {} for i = 1, 100 do t[i] = i end for i = 1, 100 do t[i] = nil end return #t") == 0);
    CHECK(run_int(S, "local t = {} t[3] = 3 t[2] = 2 t[1] = 1 return #t") == 3);   // the array part absorbs waiting keys
    CHECK(run_int(S, "local n = 0 local t = {a = 1, b = 2, c = 3} for k in pairs(t) do t[k] = nil n = n + 1 end return n + #t") == 3);
    CHECK(run_int(S, "local t = {} for i = 1, 1000 do t['k' .. i] = i end local s = 0 for k, v in pairs(t) do s = s + v end return s") == 500500);
  }

  std::printf("-- inlining of small functions\n");
  {
    // Two states that differ in the one setting; both run the same scripts. The settings are explicit, whatever the environment says.
    State on, off;
    on.open_libs();
    off.open_libs();
    on.inlining = true;
    on.inline_warm = 2;
    off.inlining = false;
    auto stats_of = [](State& st) { return st.stats; };
    std::string err;

    // A loop of calls of a small function: the first call makes the site a call of a closure, the second counts down, the third
    // rewrites the site (and is itself an ordinary call), from the fourth on the calls are inlined.
    const char* loop = "local function add(a, b) return a + b end local s = 0 for i = 1, 100 do s = add(s, i) end return s";
    auto a0 = stats_of(on), b0 = stats_of(off);
    CHECK(run_int(on, loop) == 5050);
    CHECK(run_int(off, loop) == 5050);
    CHECK(on.stats.inlined_sites == a0.inlined_sites + 1);
    CHECK(on.stats.inlined_calls == a0.inlined_calls + 97);
    CHECK(on.stats.generic_ops == a0.generic_ops);                       // the clone is specialized: no slow path
    CHECK(off.stats.inlined_sites == b0.inlined_sites && off.stats.inlined_calls == b0.inlined_calls);   // switched off: none
    CHECK(off.stats.inline_declined == b0.inline_declined);
    {
      State early;                                                       // the site is rewritten as early as possible
      early.open_libs();
      early.inlining = true;
      early.inline_warm = 1;
      CHECK(run_int(early, loop) == 5050);
      CHECK(early.stats.inlined_sites == 1 && early.stats.inlined_calls == 98);
      State never;                                                       // 0: never
      never.open_libs();
      never.inlining = true;
      never.inline_warm = 0;
      CHECK(run_int(never, loop) == 5050 && never.stats.inlined_sites == 0 && never.stats.inlined_calls == 0);
    }

    // The guard: a global function that is assigned again gives the site back to the generic call, once, and it is not inlined again.
    run(on, "function g(x) return x + 1 end function use() local s = 0 for i = 1, 50 do s = s + g(i) end return s end");
    auto c0 = stats_of(on);
    CHECK(run_int(on, "return use()") == 1325);
    CHECK(on.stats.inlined_sites == c0.inlined_sites + 1 && on.stats.deopts == c0.deopts);
    auto c1 = stats_of(on);
    run(on, "g = function(x) return x * 2 end");                         // another function
    CHECK(run_int(on, "return use()") == 2550);
    CHECK(on.stats.deopts == c1.deopts + 1);                              // the guard failed once
    auto c2 = stats_of(on);
    CHECK(run_int(on, "return use() + use()") == 5100);
    CHECK(on.stats.deopts == c2.deopts && on.stats.inlined_sites == c2.inlined_sites);   // no second rewrite, nothing inlined for it
    CHECK(on.stats.inlined_calls == c2.inlined_calls);
    run(on, "g = math.abs");                                              // a native
    CHECK(run_int(on, "return use()") == 1275);
    run(on, "g = nil");
    run(on, "return use()", &err);
    CHECK(err == "test:1: attempt to call a nil value (global 'g')");
    CHECK(on.depth == 0 && on.top == on.stack && on.cur == nullptr);

    // Closures of one function with different upvalues pass the guard (it is the function, not the closure), and read their own.
    auto d0 = stats_of(on);
    CHECK(run_int(on, "local function mk(k) return function(x) return x + k end end local a, b = mk(1), mk(100) "
                      "local function call(f) return f(1) end local s = 0 for i = 1, 20 do s = s + call(a) + call(b) end return s") == 20 * (2 + 101));
    CHECK(on.stats.deopts == d0.deopts);                                  // the second closure did not fail the guard
    CHECK(on.stats.inlined_calls > d0.inlined_calls + 30);

    // Per-site specialization: a shared tree meets integers, floats and strings and ends up generic; the clones do not, so the
    // integer and float sites never take a slow path.
    const char* mixed = "local function add(a, b) return a + b end local x, y, z = 0, 0.5, 0 "
                        "for i = 1, 100 do x = add(x, i) y = add(y, 0.25) z = add('1', i) end return x";
    auto e0 = stats_of(on), f0 = stats_of(off);
    CHECK(run_int(on, mixed) == 5050);
    CHECK(run_int(off, mixed) == 5050);
    std::uint64_t slow_on = on.stats.generic_ops - e0.generic_ops, slow_off = off.stats.generic_ops - f0.generic_ops;
    CHECK(slow_on >= 100 && slow_on <= 105);                              // the string site only
    CHECK(slow_off >= 295);                                               // the shared tree is generic for all three
    CHECK(on.stats.inlined_sites == e0.inlined_sites + 3);

    // Methods: a getter on a table, an object whose class changes under the site.
    const char* meth = "local C = {} C.__index = C function C:get() return self.v end local o = setmetatable({v = 3}, C) "
                       "local s = 0 for i = 1, 50 do s = s + o:get() end return s";
    auto m0 = stats_of(on);
    CHECK(run_int(on, meth) == 150 && run_int(off, meth) == 150);
    CHECK(on.stats.inlined_sites == m0.inlined_sites + 1 && on.stats.inlined_calls == m0.inlined_calls + 48);
    run(on, "Q = {} Q.__index = Q function Q:get() return -1 end P = setmetatable({v = 1}, Q) "
            "function run(o) local s = 0 for i = 1, 10 do s = s + o:get() end return s end");
    CHECK(run_int(on, "return run(P)") == -10);
    auto m1 = stats_of(on);
    CHECK(run_int(on, "P.get = function(self) return 100 end return run(P)") == 1000);   // the instance shadows the method
    CHECK(on.stats.deopts == m1.deopts + 1);
    CHECK(run_int(on, "P.get = nil return run(P)") == -10);

    // What is not inlined: loops, closures, varargs, multiple assignment; each is looked at once per site and left as a call.
    auto n0 = stats_of(on);
    CHECK(run_int(on, "local function lp(n) local s = 0 for i = 1, n do s = s + i end return s end local t = 0 for i = 1, 10 do t = t + lp(3) end return t") == 60);
    CHECK(run_int(on, "local function va(...) return select('#', ...) end local t = 0 for i = 1, 10 do t = t + va(i, i) end return t") == 20);
    CHECK(run_int(on, "local function sw(a, b) a, b = b, a return a end local t = 0 for i = 1, 10 do t = t + sw(i, 1) end return t") == 10);
    CHECK(on.stats.inlined_sites == n0.inlined_sites);
    CHECK(on.stats.inline_declined == n0.inline_declined + 3);
    CHECK(run_int(on, "local function mkf(k) return function() return k end end local t = 0 for i = 1, 10 do t = t + mkf(i)() end return t") == 55);
    CHECK(on.stats.inline_declined == n0.inline_declined + 4);           // a body with a closure is not inlined
    CHECK(on.stats.inlined_sites == n0.inlined_sites + 1);                // the call of what mkf returned is: the closures are of one function
    // a body over the size limit
    CHECK(run_int(on, "local function big(x) local a = x + 1 local b = a * 2 + x local c = a .. b local d = c .. a .. b .. x "
                      "if #d > 5 then return a + b + #d + #c + (a * b - c * a) // (b + 1) + (a + b) % 7 + (b - a) * #d + a * a + b * b "
                      "elseif #d > 3 then return a - b else return a * b + #d end end "
                      "local t = 0 for i = 1, 10 do t = t + big(i) end return t") != -999999);
    CHECK(on.stats.inline_declined == n0.inline_declined + 5);

    // Recursion: a recursive function is inlined into its own call site once, not without end; the depth limit still applies.
    auto r0 = stats_of(on);
    CHECK(run_int(on, "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end local t = 0 for i = 1, 20 do t = t + f(10) end return t") == 200);
    CHECK(on.stats.inlined_sites >= r0.inlined_sites + 2 && on.stats.inlined_sites <= r0.inlined_sites + 4);   // a few levels, not without end
    run(on, "local function inf(n) return inf(n + 1) + 1 end return inf(1)", &err);
    CHECK(err.find("stack overflow") != std::string::npos);
    CHECK(on.depth == 0 && on.top == on.stack && on.cur == nullptr);
    CHECK(run_int(on, "local function d(n) if n == 0 then return 0 end return 1 + d(n - 1) end return d(1000)") == 1000);
    // the limit is the same number of nested calls with and without inlining
    const char* count = "local depth = 0 local function rec() depth = depth + 1 return rec() + 1 end local ok = pcall(rec) return depth";
    CHECK(run_int(on, count) == run_int(off, count) && run_int(on, count) > 1000);

    // What clones can add to one function is bounded (8192 nodes): a chunk with 3500 different sites that call a three-node
    // function four times each inlines a part of them and declines the rest, and computes the same.
    {
      std::string big = "local function sm(x) return x + 1 end local s = 0 for i = 1, 4 do ";
      for (int i = 0; i < 3500; ++i) big += "s = s + sm(i) ";
      big += "end return s";
      auto g0 = stats_of(on);
      CHECK(run_int(on, big) == 3500 * (2 + 3 + 4 + 5));
      std::uint64_t sites = on.stats.inlined_sites - g0.inlined_sites, declined = on.stats.inline_declined - g0.inline_declined;
      CHECK(sites >= 2000 && sites <= 2800 && declined >= 700 && sites + declined == 3500);
    }

    // Errors: the same message, the same traceback (every function of the chain, innermost first, with the lines they were at).
    const char* chain = "local function c(x) if x > 6 then error('deep') end return x end\n"
                        "local function b(x) return c(x) + 1 end\n"
                        "local function a(x) return b(x) + 1 end\n"
                        "for i = 1, 9 do a(i) end";
    auto trace_of = [&](State& st) {
      nfcast::Closure* cl = st.load(chain, "chain", &err);
      Rets o;
      std::vector<std::string> tr;
      std::string msg;
      auto before = st.stats.inlined_calls;
      try {
        st.call(Value::function(cl), nullptr, 0, o);
      } catch (Thrown& t) {
        tr = t.trace;
        msg = st.tostring(t.v);
      }
      return std::make_tuple(msg, tr, st.stats.inlined_calls - before);
    };
    State early_t;                                                        // calls inlined as early as possible: the error is raised inside three
    early_t.open_libs();                                                  // inlined bodies, one in the other
    early_t.inlining = true;
    early_t.inline_warm = 1;
    auto t_on = trace_of(on), t_off = trace_of(off), t_early = trace_of(early_t);
    CHECK(std::get<0>(t_on) == "chain:1: deep" && std::get<0>(t_on) == std::get<0>(t_off) && std::get<0>(t_early) == std::get<0>(t_off));
    CHECK(std::get<2>(t_on) > 0 && std::get<2>(t_early) > std::get<2>(t_on) && std::get<2>(t_off) == 0);   // inlined bodies were running
    CHECK(std::get<1>(t_on) == std::get<1>(t_off) && std::get<1>(t_early) == std::get<1>(t_off));
    {
      const std::vector<std::string>& tr = std::get<1>(t_early);          // c, b, a, the chunk: a frame for every inlined body
      CHECK(tr.size() == 4 && tr[0].find("chain:1:") == 0 && tr[1].find("chain:2:") == 0 && tr[2].find("chain:3:") == 0 &&
            tr[3].find("chain:4:") == 0);
      CHECK(tr.size() == 4 && tr[0].find("local 'c'") != std::string::npos && tr[1].find("local 'b'") != std::string::npos &&
            tr[2].find("local 'a'") != std::string::npos && tr[3].find("main chunk") != std::string::npos);
    }
    CHECK(on.depth == 0 && on.top == on.stack && on.cur == nullptr && early_t.depth == 0 && early_t.cur == nullptr);

    // The host calls back into the script from inside an inlined body, and an error comes back through the inlined frames.
    {
      State cbs;
      cbs.open_libs();
      cbs.inlining = true;
      cbs.inline_warm = 1;
      cbs.globals->set_str(cbs, cbs.str("cb"), Value::function(cbs.new_native(native_cb, "cb")));
      CHECK(run_int(cbs, "local function twice(x) return x * 2 end local function viacb(x) return cb(twice, x) + 1 end "
                         "local t = 0 for i = 1, 20 do t = t + viacb(i) end return t") == 440);
      CHECK(cbs.stats.inlined_calls == 18);                          // viacb, from the third call of its site on
      CHECK(run_int(cbs, "local function boom(f) return cb(f, 1) end local n = 0 "
                         "for i = 1, 10 do local ok, e = pcall(function() return boom(function() error('x' .. i) end) end) "
                         "if not ok and e == 'test:1: x' .. i then n = n + 1 end end return n") == 10);
      CHECK(cbs.depth == 0 && cbs.top == cbs.stack && cbs.cur == nullptr && cbs.pcall_depth == 0);
      std::string cerr;
      run(cbs, "local function boom(f) return cb(f, 1) end for i = 1, 5 do boom(function() local t = nil; return t.x end) end", &cerr);
      CHECK(cerr == "test:1: attempt to index a nil value (local 't')");
      CHECK(cbs.depth == 0 && cbs.top == cbs.stack && cbs.cur == nullptr);
      CHECK(run_int(cbs, "return 1 + 1") == 2);
    }

    // The collector: bodies that allocate and mention strings of their own, under a collector that runs at every safe point.
    {
      State gc;
      gc.open_libs();
      gc.inlining = true;
      gc.inline_warm = 1;
      gc.gc_stress = true;
      CHECK(run_int(gc, "local function mk(i) return {i, 'item-number-' .. i, {i * 2}} end "
                        "local function lab(t) return t[2] .. ':' .. t[3][1] end local n = 0 "
                        "for i = 1, 200 do local t = mk(i) n = n + #lab(t) + #lab(mk(i + 1)) end return n") != -999999);
      CHECK(gc.stats.inlined_calls > 500 && gc.stats.gc_cycles > 500);
      // a callee dropped by the program while a caller still holds a rewritten site; the site meets another function afterwards
      run(gc, "local chunk = load('local function helper(t) return t.name .. \"-a-constant-only-the-helper-has\" end return helper') "
              "holder = chunk() local function use(t) return holder(t) end for i = 1, 5 do use({name = 'n' .. i}) end user = use");
      run(gc, "holder = nil");
      gc.collect();
      gc.collect();
      Value r = run(gc, "holder = function(t) return 'other ' .. t.name end return user({name = 'x'})");
      CHECK(r.t == nfcast::T_STR && r.s()->view() == "other x");
    }
  }

  std::printf("-- State is reusable\n");
  {
    State S2;
    S2.open_libs();
    S2.globals->set_str(S2, S2.str("make_probe"), Value::function(S2.new_native(native_make_probe, "make_probe")));
    int before = Probe::live;
    run(S2, "p = make_probe(1) q = {make_probe(2), make_probe(3)}");
    CHECK(Probe::live == before + 3);
  }
  S.collect();
  CHECK(Probe::live == 0);                                // closing a State deletes the host objects it still held

  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
