// Engine-level checks of nfcast that need the C++ API: the nodes specialize (and give way when their guard fails), the
// collector frees what is unreachable and keeps what is pinned or referenced, host objects, error values and the state of
// the interpreter after errors. Exit status 0 when every check passes. Run by tests/ast/run.sh.
#include <cstdio>
#include <string>

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
