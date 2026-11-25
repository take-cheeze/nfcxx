// Checks of the machine-code tier for loops (docs/notes/ast.md, "JIT") through the C++ API: for each loop of the test programs the
// JIT's result is the interpreter's, the counters say what the JIT did (compiled, entered, refused, a guard that failed), and a set of
// generated integer loops (with wraparound, nested loops, breaks, and conditions) agree with the interpreter. The JIT runs on any host
// as far as these checks go; on a host that is not x86-64 Linux it refuses every loop, and the checks say so and pass.
// Exit status 0 when every check passes.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "nfcast.hpp"
#include "nfcast_jit.hpp"

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

// Runs CODE as a chunk and returns its results as text ("1,2.5,true"), or "ERR:" and the message.
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

// The JIT on, every loop taken over at its first edge (after one iteration in the interpreter); the C tier's loops are off, and
// the function-level threshold is out of reach (the programs here have no functions).
static void jit_on(State& S) {
  TierOptions o;
  o.mode = TierOptions::Sync;
  o.jit = true;
  o.osr = false;
  o.threshold = 1000000;
  o.loop_threshold = 1;
  S.enable_tier(o);
}

// What the counters must say about a program's loops (ENTERED: compiled, and taken over at least twice).
enum Expect { ANY, COMPILED, ENTERED, REFUSED, GUARD };

struct Case {
  const char* name;
  const char* code;
  Expect want;
};

static const Case cases[] = {
    {"while with comparisons",
     "local s, i = 0, 0\n"
     "while i < 1000 do\n"
     "  if i < 500 then s = s + i * 3 elseif i < 800 then s = s - i else s = s + 1 end\n"
     "  i = i + 1\n"
     "end\n"
     "return s, i",
     COMPILED},
    {"nested numeric for loops with a negative step and a break",
     "local acc = 0\n"
     "for i = 1, 60 do\n"
     "  for j = 10, 1, -3 do\n"
     "    if j == 4 then break end\n"
     "    acc = acc + i * j\n"
     "  end\n"
     "  for k = i, 100, 7 do acc = acc - k end\n"
     "  if acc > 100000 then break end\n"
     "end\n"
     "return acc",
     COMPILED},
    {"repeat with wraparound and a break",
     "local x, n = 1, 0\n"
     "repeat\n"
     "  x = x * 6364136223846793005 + 1442695040888963407\n"
     "  n = n + 1\n"
     "  if n >= 300 then break end\n"
     "until x < 0\n"
     "return x, n",
     COMPILED},
    {"overflow wraps as the interpreter's integers do",
     "local m = 9223372036854775807\n"
     "local r = 0\n"
     "for i = 1, 5 do m = m + 1 r = r + 1 end\n"
     "local p = 3037000500\n"
     "for i = 1, 4 do p = p * p end\n"
     "local q = -9223372036854775807\n"
     "for i = 1, 3 do q = q - 2 end\n"
     "return m, r, p, q",
     COMPILED},
    {"a live-in that is a float at entry: the guard fails, the interpreter runs",
     "local f = 2.5\n"
     "local s, i = 0, 0\n"
     "while i < 10 do s = s + f i = i + 1 end\n"
     "return s",
     GUARD},
    {"integer division is refused (it needs a check for zero)",
     "local q = 0\n"
     "for i = 1, 20 do q = q + i // 3 end\n"
     "return q",
     REFUSED},
    {"a table in the loop is refused",
     "local t = {}\n"
     "for i = 1, 10 do t[i] = i end\n"
     "return #t",
     REFUSED},
    {"a float for loop is refused",
     "local s = 0\n"
     "for x = 0.5, 3 do s = s + 1 end\n"
     "return s",
     REFUSED},
    {"a for loop with a float limit runs as an integer loop",
     "local s = 0\n"
     "for i = 1, 10.5 do s = s + i end\n"
     "return s",
     COMPILED},
    {"a multiple assignment and a while true with a break",
     "local a, b = 1, 2\n"
     "local n = 0\n"
     "while true do\n"
     "  a, b = b, a\n"
     "  n = n + 1\n"
     "  if n == 11 then break end\n"
     "end\n"
     "return a, b, n",
     COMPILED},
    {"locals declared in the loop, and a while inside it",
     "local total = 0\n"
     "for i = 1, 50 do\n"
     "  local j = 0\n"
     "  local k = i\n"
     "  while k > 0 do j = j + k k = k - 3 end\n"
     "  total = total + j\n"
     "end\n"
     "return total",
     COMPILED},
    {"a while re-entered many times, inside a loop that is refused",
     "local t = {}\n"
     "local total = 0\n"
     "for k = 1, 6 do\n"
     "  t[k] = k\n"
     "  local x = 0\n"
     "  while x < k * 10 do x = x + 3 total = total + 1 end\n"
     "end\n"
     "return total",
     ENTERED},
    {"conditions: and, or, not, == and ~=",
     "local c, d = 0, 0\n"
     "for i = 1, 100 do\n"
     "  if (i == 50 or i ~= 3) and not (i > 90) then c = c + 1 end\n"
     "  if i >= 10 and i <= 20 or i == 99 then d = d + i end\n"
     "end\n"
     "return c, d",
     COMPILED},
    {"a local captured by a closure is refused",
     "local x = 0\n"
     "local function g() x = x + 1 return x end\n"
     "for i = 1, 5 do x = x + i end\n"
     "return g(), x",
     REFUSED},
    {"a return inside the loop is refused",
     "local s = 0\n"
     "for i = 1, 5 do s = s + i if s > 3 then return s end end\n"
     "return -1",
     REFUSED},
};

// The generated loops: integer statements and expressions over three locals and the loop variable, with wraparound, nested ifs and
// while loops, and conditions. Every one is in the subset, so each must compile and run, and must give the interpreter's results.
struct Rng {
  unsigned long long s;
  unsigned next() {
    s = s * 6364136223846793005ULL + 1442695040888963407ULL;
    return static_cast<unsigned>(s >> 33);
  }
  int pick(int n) { return static_cast<int>(next() % static_cast<unsigned>(n)); }
};

static std::string gen_expr(Rng& r, int depth) {
  static const char* vars[] = {"a", "b", "c", "i"};
  if (depth <= 0 || r.pick(3) == 0) {
    switch (r.pick(4)) {
      case 0: return vars[r.pick(4)];
      case 1: return std::to_string(r.pick(20) - 10);
      case 2: return "9223372036854775807";
      default: return std::to_string(r.next() % 100000u);
    }
  }
  switch (r.pick(5)) {
    case 0: return "(" + gen_expr(r, depth - 1) + " + " + gen_expr(r, depth - 1) + ")";
    case 1: return "(" + gen_expr(r, depth - 1) + " - " + gen_expr(r, depth - 1) + ")";
    case 2: return "(" + gen_expr(r, depth - 1) + " * " + gen_expr(r, depth - 1) + ")";
    case 3: return "(-" + gen_expr(r, depth - 1) + ")";
    default: return "(" + gen_expr(r, depth - 1) + " * 6364136223846793005)";
  }
}

static std::string gen_cond(Rng& r, int depth) {
  static const char* ops[] = {"<", "<=", ">", ">=", "==", "~="};
  if (depth > 0 && r.pick(4) == 0) {
    switch (r.pick(3)) {
      case 0: return "(" + gen_cond(r, depth - 1) + " and " + gen_cond(r, depth - 1) + ")";
      case 1: return "(" + gen_cond(r, depth - 1) + " or " + gen_cond(r, depth - 1) + ")";
      default: return "(not (" + gen_cond(r, depth - 1) + "))";  // not (a < b), not `not a < b` (that is (not a) < b)
    }
  }
  return gen_expr(r, 2) + " " + ops[r.pick(6)] + " " + gen_expr(r, 2);
}

static std::string gen_stmt(Rng& r, int depth, int& wcount) {
  static const char* targets[] = {"a", "b", "c"};
  switch (depth > 0 ? r.pick(6) : r.pick(3)) {
    case 0:
    case 1: return std::string(targets[r.pick(3)]) + " = " + gen_expr(r, 3) + "\n";
    case 2: {
      std::string t = "t" + std::to_string(wcount);
      ++wcount;
      return "local " + t + " = " + gen_expr(r, 2) + " b = b + " + t + "\n";
    }
    case 3:
      return "if " + gen_cond(r, 2) + " then " + gen_stmt(r, depth - 1, wcount) + " else " + gen_stmt(r, depth - 1, wcount) + " end\n";
    case 4: {
      // a while with its own counter, so that it ends
      std::string w = "w" + std::to_string(wcount);
      ++wcount;
      return "do local " + w + " = 0 while " + w + " < " + std::to_string(1 + r.pick(4)) + " do " + w + " = " + w + " + 1 " +
             gen_stmt(r, depth - 1, wcount) + " end end\n";
    }
    default:
      if (r.pick(3) == 0) return "if " + gen_cond(r, 1) + " then break end\n";
      return gen_stmt(r, depth - 1, wcount);
  }
}

static std::string gen_program(Rng& r) {
  int wcount = 0;
  std::string body;
  int n = 2 + r.pick(4);
  for (int k = 0; k < n; ++k) body += gen_stmt(r, 2, wcount);
  std::string loop = "for i = 1, " + std::to_string(3 + r.pick(40)) + " do\n" + body + "end\n";
  if (r.pick(2)) loop = "for i = 1, " + std::to_string(2 + r.pick(20)) + " do\n" + "for j = 1, 3 do\n" + body + "end\nend\n";
  return "local a, b, c = " + std::to_string(r.next()) + ", " + std::to_string(r.pick(100) - 50) + ", 9223372036854775807\n" +
         loop + "return a, b, c";
}

int main() {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  // The default is off: no tier, no counters.
  {
    State S;
    S.open_libs();
    CHECK(S.tier == nullptr);
    CHECK(eval(S, "local s = 0 for i = 1, 100 do s = s + i end return s") == "5050");
    CHECK(S.stats.jit_compiled == 0 && S.stats.jit_entries == 0 && S.stats.jit_guard_misses == 0);
    CHECK(S.stats.jit_bailouts == 0 && S.stats.jit_refused == 0);
  }

  bool avail = nfcast::jit::available();
  std::printf("-- JIT %s on this host\n", avail ? "available (x86-64 Linux)" : "unavailable: every loop is refused");

  std::printf("-- loops\n");
  for (const Case& c : cases) {
    State P;
    P.open_libs();
    TierOptions off;
    off.mode = TierOptions::Off;
    P.enable_tier(off);
    std::string want = eval(P, c.code);

    State S;
    S.open_libs();
    jit_on(S);
    std::string got = eval(S, c.code);
    const nfcast::Stats& st = S.stats;
    bool same = got == want;
    CHECK(same);
    CHECK(st.jit_bailouts == st.jit_guard_misses);  // no run-time deopts in this slice
    if (!same) std::printf("  %s: got %s, want %s\n", c.name, got.c_str(), want.c_str());
    if (!avail) {
      CHECK(st.jit_compiled == 0 && st.jit_entries == 0);
      CHECK(st.jit_refused >= 1);
    } else {
      switch (c.want) {
        case COMPILED: CHECK(st.jit_compiled >= 1 && st.jit_entries >= 1 && st.jit_guard_misses == 0 && st.jit_refused == 0); break;
        case ENTERED: CHECK(st.jit_compiled >= 1 && st.jit_entries >= 2 && st.jit_guard_misses == 0); break;
        case REFUSED: CHECK(st.jit_refused >= 1 && st.jit_entries == 0); break;
        case GUARD: CHECK(st.jit_guard_misses >= 1 && st.jit_entries == 0); break;
        case ANY: break;
      }
    }
    std::printf("%s  %-62s %s  (compiled %llu, entries %llu, refused %llu, guard misses %llu)\n", same ? "ok  " : "FAIL",
                c.name, got.c_str(), static_cast<unsigned long long>(st.jit_compiled), static_cast<unsigned long long>(st.jit_entries),
                static_cast<unsigned long long>(st.jit_refused), static_cast<unsigned long long>(st.jit_guard_misses));
  }

  // Generated loops: each must agree with the interpreter, and (on this host) compile without a refusal.
  std::printf("-- generated loops\n");
  Rng r{0x9E3779B97F4A7C15ULL};
  unsigned long long entries = 0, compiled = 0;
  int gen_fail = 0;
  const int kPrograms = 300;
  for (int k = 0; k < kPrograms; ++k) {
    std::string code = gen_program(r);
    State P;
    P.open_libs();
    TierOptions off;
    off.mode = TierOptions::Off;
    P.enable_tier(off);
    std::string want = eval(P, code);
    State S;
    S.open_libs();
    jit_on(S);
    std::string got = eval(S, code);
    entries += S.stats.jit_entries;
    compiled += S.stats.jit_compiled;
    bool ok = got == want && S.stats.jit_bailouts == S.stats.jit_guard_misses;
    if (avail) ok = ok && S.stats.jit_refused == 0;
    if (!ok) {
      ++gen_fail;
      std::printf("FAIL generated program %d:\n%s\n  got %s\n  want %s\n", k, code.c_str(), got.c_str(), want.c_str());
    }
  }
  CHECK(gen_fail == 0);
  if (avail) CHECK(compiled >= static_cast<unsigned long long>(kPrograms) && entries >= static_cast<unsigned long long>(kPrograms));
  std::printf("ok   %d generated programs: %llu loops compiled, %llu takeovers\n", kPrograms, compiled, entries);

  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
