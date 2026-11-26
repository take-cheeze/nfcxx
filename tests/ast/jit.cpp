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

// What the counters must say about a program's loops (ENTERED: compiled, and taken over at least twice; DEOPT: compiled, and the
// code stopped at a zero divisor once, which the error of the program shows).
enum Expect { ANY, COMPILED, ENTERED, REFUSED, GUARD, DEOPT };

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
    {"float division is refused (the result is a float, outside the subset)",
     "local q = 0\n"
     "for i = 1, 20 do q = q + i / 3 end\n"
     "return q",
     REFUSED},
    {"a power is refused",
     "local q = 0\n"
     "for i = 1, 20 do q = q + i ^ 2 end\n"
     "return q",
     REFUSED},
    {"floor division and modulo on positive and negative operands, constant and compound, as the interpreter's",
     "local q, r = 0, 0\n"
     "for a = -20, 20 do\n"
     "  for b = -5, 5 do\n"
     "    if b ~= 0 then\n"
     "      q = q * 31 + a // b + (a * 3 - 1) // (b * 2 - 1)\n"
     "      r = r * 37 + a % b + (a * 5 + 2) % (b + 7) + a % 4 - a // 3\n"
     "    end\n"
     "  end\n"
     "end\n"
     "return q, r",
     COMPILED},
    {"floor division by -1 and modulo by -1 at the smallest integer: the wraparound, no error",
     "local m = -9223372036854775807 - 1\n"
     "local q, r, n = 0, 0, 0\n"
     "for i = 1, 4 do\n"
     "  q = q + m // -1\n"
     "  r = r + m % -1 + (m + i) % -1\n"
     "  n = n + (m + i) // -1\n"
     "end\n"
     "return m // -1, m % -1, q, r, n",
     COMPILED},
    {"a zero divisor on the seventh iteration: the interpreter's error, at the same line, with the loop's state",
     "local s = 0\n"
     "for i = 1, 9 do\n"
     "  s = s + 100 // (7 - i)\n"
     "end\n"
     "return s",
     DEOPT},
    {"a floor division by zero in a while condition, after the divisions that are fine",
     "local z, n = 4, 0\n"
     "while 100 // z > 0 do\n"
     "  z = z - 1\n"
     "  n = n + 1\n"
     "end\n"
     "return n",
     DEOPT},
    {"a zero divisor in a compound operand, with a value pushed for the left one",
     "local s = 0\n"
     "for i = 1, 9 do\n"
     "  s = s + ((i * 2) + ((i * 3) // (5 - i)))\n"
     "end\n"
     "return s",
     DEOPT},
    {"a floor division by zero in the limit of an inner for loop",
     "local s = 0\n"
     "for i = 1, 5 do\n"
     "  for j = 1, 10 // (3 - i) do s = s + j end\n"
     "end\n"
     "return s",
     DEOPT},
    {"a modulo by zero in a repeat's condition, the divisor a live local that the loop counts",
     "local n = 0\n"
     "repeat n = n + 1 until 7 % (3 - n) < 0\n"
     "return n",
     DEOPT},
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
    {"six live integer locals, more than the registers: each written back at the end",
     "local a, b, c, d, e, f = 1, 2, 3, 4, 5, 6\n"
     "for i = 1, 1000 do\n"
     "  a = a + i\n"
     "  b = b + a\n"
     "  c = c + b * 3\n"
     "  d = d - c\n"
     "  e = e + d\n"
     "  f = f + i * 6364136223846793005\n"
     "end\n"
     "return a, b, c, d, e, f, a + b + c + d + e + f",
     COMPILED},
    {"more live locals than registers, read-only and assigned, with two exits (a condition and a break)",
     "local k1, k2, k3, k4, k5 = 7, 11, 13, 17, 19\n"
     "local s, t, u = 0, 0, 0\n"
     "local n = 0\n"
     "while n < 700 do\n"
     "  n = n + 1\n"
     "  s = s + k1 * n + k2\n"
     "  t = t + k3 - s\n"
     "  u = u + k4 * k5\n"
     "  if t > 100000000000 then break end\n"
     "end\n"
     "return s, t, u, n, k1, k2, k3, k4, k5",
     COMPILED},
    {"nested for loops with a break from the inner one, and five locals updated in the outer one",
     "local x, y, z, w, v = 0, 1, 2, 3, 4\n"
     "for i = 1, 40 do\n"
     "  for j = 1, 30 do\n"
     "    x = x + i * j\n"
     "    if x > 50000 then break end\n"
     "    y = y + z\n"
     "  end\n"
     "  z = z + w - v\n"
     "  w = w + 1\n"
     "  v = v * 2 - w\n"
     "end\n"
     "return x, y, z, w, v",
     COMPILED},
    {"bitwise and, or, xor and not on positive, negative and large operands",
     "local s, t, u = 0, 0, 0\n"
     "local big = 9223372036854775807\n"
     "local lo = -9223372036854775807 - 1\n"
     "for i = 1, 200 do\n"
     "  local p = i * 1234567\n"
     "  local n = -i * 7654321\n"
     "  s = s + (p & n) + (p | n) + (p ~ n) + (~p)\n"
     "  t = t ~ (n & big) ~ (p | lo) ~ (lo & n)\n"
     "  u = u + ((n | big) & ~n) - ((p ~ big) | i)\n"
     "end\n"
     "return s, t, u",
     COMPILED},
    {"xorshift-style bitwise operators in a while loop",
     "local x, y, n = 88172645463325252, 362436069, 0\n"
     "while n < 500 do\n"
     "  x = x ~ (x << 13)\n"
     "  x = x ~ (x >> 7)\n"
     "  x = x ~ (x << 17)\n"
     "  y = (y & 0xFFFF) | (x & ~0xFFFF)\n"
     "  n = n + 1\n"
     "end\n"
     "return x, y, n",
     COMPILED},
    {"shifts with counts 0, 63, 64, 65, negative counts and the most negative integer",
     "local r = 0\n"
     "for i = 1, 40 do\n"
     "  r = r + (i << 0) + (i >> 0) + (i << 63) + (i >> 63) + (i << 64) + (i >> 64)\n"
     "  r = r + (i << -1) + (i >> -1) + (i << -63) + (i >> -63) + (i << -64) + (i >> -64)\n"
     "  r = r + (i << 65) + (i >> -65) + (-1 >> 1) + (-1 << 63) + (-1 >> 64)\n"
     "end\n"
     "local m = -9223372036854775807 - 1\n"
     "local v = -1234567\n"
     "r = r ~ (v << m) ~ (v >> m) ~ (v >> 9223372036854775807)\n"
     "return r",
     COMPILED},
    {"shift counts from -149 to 149 taken from the loop, and a shift count that is a local",
     "local acc = 0\n"
     "local c = -70\n"
     "for i = 1, 300 do\n"
     "  local k = i - 150\n"
     "  acc = acc ~ (-7 << k) ~ (-7 >> k) ~ (i << k) ~ (i >> k)\n"
     "  acc = acc ~ (acc << c) ~ (acc >> c)\n"
     "  c = c + 1\n"
     "  if c > 70 then c = -70 end\n"
     "end\n"
     "return acc, c",
     COMPILED},
    {"shifts and bitwise operators in conditions, and a bitwise operator on a loop variable inside a while",
     "local hits, j = 0, 0\n"
     "while j < 300 do\n"
     "  j = j + 1\n"
     "  if (j & 4) ~= 0 and (j >> 1) < 100 then hits = hits + 1 end\n"
     "  if ~j == -j - 1 and (j << 2) > 1000 then hits = hits + 1000 end\n"
     "end\n"
     "return hits, j",
     COMPILED},
    {"bitwise operators mixed with a refused operator: the loop falls back and gives the interpreter's result",
     "local s, t = 0, 0\n"
     "for i = 1, 50 do\n"
     "  s = (s ~ i) & 0xFFFF\n"
     "  t = t + (i ^ 2)\n"
     "end\n"
     "return s, t",
     REFUSED},
    {"a bitwise operator on a float with an integer value: the guard fails, the interpreter runs the loop",
     "local f = 2.0\n"
     "local s = 0\n"
     "for i = 1, 10 do s = s + (i | f) end\n"
     "return s",
     GUARD},
    {"a float among six locals: the guard fails, and the interpreter runs the loop",
     "local f = 0.5\n"
     "local a, b, c, d, e, g = 1, 2, 3, 4, 5, 6\n"
     "local s = 0\n"
     "for i = 1, 10 do a = a + i b = b + a c = c + f s = s + e + g end\n"
     "return a, b, c, d, e, g, s",
     GUARD},
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

// Set for the batch of programs with the bitwise operators (the other batch is generated as before, the same programs).
static bool gen_bits = false;

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
  switch (gen_bits ? r.pick(12) : r.pick(6)) {
    case 0: return "(" + gen_expr(r, depth - 1) + " + " + gen_expr(r, depth - 1) + ")";
    case 1: return "(" + gen_expr(r, depth - 1) + " - " + gen_expr(r, depth - 1) + ")";
    case 2: return "(" + gen_expr(r, depth - 1) + " * " + gen_expr(r, depth - 1) + ")";
    case 3: return "(-" + gen_expr(r, depth - 1) + ")";
    case 4: return "(" + gen_expr(r, depth - 1) + " * 6364136223846793005)";
    case 5: {  // floor division and modulo by a constant that is not zero (-1 included): no zero divisor, so no deopt
      static const char* divisors[] = {"-1", "2", "-3", "7", "-7", "1", "-2", "9223372036854775807"};
      return "(" + gen_expr(r, depth - 1) + (r.pick(2) ? " // " : " % ") + divisors[r.pick(8)] + ")";
    }
    case 6: return "(" + gen_expr(r, depth - 1) + " & " + gen_expr(r, depth - 1) + ")";
    case 7: return "(" + gen_expr(r, depth - 1) + " | " + gen_expr(r, depth - 1) + ")";
    case 8: return "(" + gen_expr(r, depth - 1) + " ~ " + gen_expr(r, depth - 1) + ")";
    case 9:  // a shift by a constant count from -70 to 70, or by a generated one (which is often 64 or more, or negative)
      return "(" + gen_expr(r, depth - 1) + " << " + (r.pick(2) ? "(" + std::to_string(r.pick(141) - 70) + ")" : gen_expr(r, 1)) + ")";
    case 10:
      return "(" + gen_expr(r, depth - 1) + " >> " + (r.pick(2) ? "(" + std::to_string(r.pick(141) - 70) + ")" : gen_expr(r, 1)) + ")";
    default: return "(~" + gen_expr(r, depth - 1) + ")";
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
    // A deopt (a zero divisor) is counted in jit_bailouts too: one for the DEOPT cases, none for the others.
    CHECK(st.jit_bailouts == st.jit_guard_misses + (avail && c.want == DEOPT ? 1 : 0));
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
        case DEOPT: CHECK(st.jit_compiled >= 1 && st.jit_bailouts == 1 && st.jit_guard_misses == 0 && st.jit_refused == 0); break;
        case ANY: break;
      }
    }
    std::printf("%s  %-62s %s  (compiled %llu, entries %llu, refused %llu, guard misses %llu)\n", same ? "ok  " : "FAIL",
                c.name, got.c_str(), static_cast<unsigned long long>(st.jit_compiled), static_cast<unsigned long long>(st.jit_entries),
                static_cast<unsigned long long>(st.jit_refused), static_cast<unsigned long long>(st.jit_guard_misses));
  }

  // A division by zero inside a function called under pcall: the loop of the function is compiled, the zero divisor is a deopt (the
  // interpreter raises the error from the statement, with the same message), and pcall catches it, with the JIT on or off. The
  // third call has no zero divisor and runs to its end (in the machine code, or as native code of the C tier once the tier has
  // compiled the function: the counters do not say which, so only the results are checked).
  std::printf("-- errors under pcall\n");
  {
    const char* code =
        "local function f(n)\n"
        "  local s = 0\n"
        "  for i = 1, n do s = s + 100 // (i - 5) end\n"
        "  return s\n"
        "end\n"
        "local function g(n)\n"
        "  local s = 0\n"
        "  for i = 1, n do s = s + (i & 7) + (100 % (i - 3)) end\n"
        "  return s\n"
        "end\n"
        "local ok1, e1 = pcall(f, 10)\n"
        "local ok2, e2 = pcall(g, 10)\n"
        "local ok3, e3 = pcall(f, 4)\n"
        "return ok1, e1, ok2, e2, ok3, e3";
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
    std::printf("  interpreter: %s\n  jit on:      %s\n", want.c_str(), got.c_str());
    CHECK(got == want);
    CHECK(want.rfind("false,", 0) == 0);  // the first error is caught by pcall, not raised out of the chunk
    CHECK(want.find("divide by zero") != std::string::npos);
    CHECK(want.find("'n%0'") != std::string::npos);  // the modulo error, from the second function
    CHECK(S.stats.jit_bailouts == S.stats.jit_guard_misses + (avail ? 2 : 0));  // the two zero divisors, the deopts
    if (avail) CHECK(S.stats.jit_compiled >= 2 && S.stats.jit_refused == 0);
  }

  // Generated loops: each must agree with the interpreter, and (on this host) compile without a refusal. The second batch has
  // the bitwise operators and the shifts; the first is the same as before them.
  std::printf("-- generated loops\n");
  unsigned long long entries = 0, compiled = 0;
  int gen_fail = 0;
  const int kPrograms = 300;
  for (int batch = 0; batch < 2; ++batch) {
    gen_bits = batch == 1;
    Rng r = batch == 0 ? Rng{0x9E3779B97F4A7C15ULL} : Rng{0x2545F4914F6CDD1DULL};
    unsigned long long b_entries = 0, b_compiled = 0;
    int b_fail = 0;
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
      b_entries += S.stats.jit_entries;
      b_compiled += S.stats.jit_compiled;
      bool ok = got == want && S.stats.jit_bailouts == S.stats.jit_guard_misses;
      if (avail) ok = ok && S.stats.jit_refused == 0;
      if (!ok) {
        ++b_fail;
        std::printf("FAIL generated program %d (%s):\n%s\n  got %s\n  want %s\n", k, batch ? "bitwise" : "arithmetic",
                    code.c_str(), got.c_str(), want.c_str());
      }
    }
    gen_fail += b_fail;
    entries += b_entries;
    compiled += b_compiled;
    if (avail) CHECK(b_compiled >= static_cast<unsigned long long>(kPrograms) && b_entries >= static_cast<unsigned long long>(kPrograms));
    std::printf("ok   %d %s generated programs: %llu loops compiled, %llu takeovers%s\n", kPrograms,
                batch ? "bitwise" : "arithmetic", b_compiled, b_entries, b_fail ? " (FAILURES)" : "");
  }
  gen_bits = false;
  CHECK(gen_fail == 0);

  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
