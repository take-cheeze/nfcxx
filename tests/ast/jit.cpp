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

// The printed results with the sign of a nan dropped. The sign of a nan made from two nan operands is not the language's: C and IEEE 754
// leave the propagation of a nan's sign to the implementation, and the interpreter's own result depends on the operand order its C
// compiler chooses, which differs between the back ends (the JIT takes the left operand's nan, as SSE does). The mixed batch compares
// with it dropped; every other value, and every explicit case, is compared exactly.
static std::string without_nan_sign(std::string s) {
  for (std::size_t p = s.find("-nan"); p != std::string::npos; p = s.find("-nan", p)) s.erase(p, 1);
  return s;
}

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
// MIXED: compiled, and a takeover refused by the guard after one that ran (a float local compiled as a float, entered with an integer).
enum Expect { ANY, COMPILED, ENTERED, REFUSED, GUARD, DEOPT, MIXED };

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
    {"a float added to an integer local after the takeover: refused (the local would change type)",
     "local f = 2.5\n"
     "local s, i = 0, 0\n"
     "while i < 10 do if i == 5 then s = s + f end i = i + 1 end\n"
     "return s",
     REFUSED},
    {"a float local compiled as a float, entered later with an integer: the guard fails on those entries",
     "local x = 2.5\n"
     "local s = 0.0\n"
     "for k = 1, 4 do\n"
     "  local y = (k == 1) and x or 3\n"
     "  local i = 0\n"
     "  while i < 3 do s = s + y i = i + 1 end\n"
     "end\n"
     "return s",
     MIXED},
    {"an integer local that takes a float quotient after the takeover: refused (the local would change type)",
     "local q = 0\n"
     "for i = 1, 20 do if i == 5 then q = q + i / 3 end end\n"
     "return q",
     REFUSED},
    {"a float local assigned an integer after the takeover: refused",
     "local x = 0.5\n"
     "for i = 1, 5 do if i == 3 then x = i end end\n"
     "return x",
     REFUSED},
    {"a float local and an integer local in sibling blocks, with the frame slot reused: each keeps its type",
     "local acc, n = 0.0, 0\n"
     "for i = 1, 30 do\n"
     "  do local t = i / 4 acc = acc + t end\n"
     "  do local k = i * 3 n = n + k end\n"
     "  do local t2 = 2.5 * i acc = acc - t2 + 1 end\n"
     "  do local u = i // 2 n = n - u end\n"
     "end\n"
     "return acc, n",
     COMPILED},
    {"float division with a float accumulator, and a zero divisor that is not an error",
     "local q, z = 0.0, 0.0\n"
     "for i = 1, 20 do q = q + i / 3 + 1 / (z + i - 1) end\n"
     "return q",
     COMPILED},
    {"a power with a float accumulator",
     "local q = 0.0\n"
     "for i = 1, 20 do q = q + i ^ 2 + 2 ^ (i / 4) end\n"
     "return q",
     COMPILED},
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
    {"a float for loop runs compiled",
     "local s = 0\n"
     "for x = 0.5, 3 do s = s + 1 end\n"
     "return s",
     COMPILED},
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
    {"bitwise operators with a power added to an integer local after the takeover: the loop falls back and gives the interpreter's result",
     "local s, t = 0, 0\n"
     "for i = 1, 50 do\n"
     "  s = (s ~ i) & 0xFFFF\n"
     "  if i == 7 then t = t + (i ^ 2) end\n"
     "end\n"
     "return s, t",
     REFUSED},
    {"a bitwise operator on a float, even one with an integer value: refused",
     "local f = 2.0\n"
     "local s = 0\n"
     "for i = 1, 10 do s = s + (i | f) end\n"
     "return s",
     REFUSED},
    {"a float added to one of six integer locals after the takeover: refused, and the interpreter runs the loop",
     "local f = 0.5\n"
     "local a, b, c, d, e, g = 1, 2, 3, 4, 5, 6\n"
     "local s = 0\n"
     "for i = 1, 10 do a = a + i b = b + a if i == 6 then c = c + f end s = s + e + g end\n"
     "return a, b, c, d, e, g, s",
     REFUSED},
    {"float locals with the four operators, mixed with integers, and a float that the loop declares",
     "local x, y = 0.5, 1.0\n"
     "local n = 0\n"
     "for i = 1, 200 do\n"
     "  local t = x * 1.0001 + i / 7\n"
     "  x = t - y / (i + 0.5)\n"
     "  y = y * 0.999 + (i - 3) * 0.25 - 2 / i\n"
     "  n = n + 1\n"
     "end\n"
     "return x, y, n",
     COMPILED},
    {"float division by zero: inf, -inf and nan, with no error, as the interpreter gives them",
     "local zero, s, t, u = 0.0, 0.0, 0.0, 0.0\n"
     "local a, b, c, d = 1 / zero, -1 / zero, zero / zero, 1.0 / (zero * -1)\n"
     "for i = 1, 4 do\n"
     "  s = s + 1 / (zero + i - 1)\n"
     "  t = t + -1 / (zero + i - 1)\n"
     "  u = u + (zero + i - 1) / (zero + i - 1)\n"
     "end\n"
     "return a, b, c, d, s, t, u",
     COMPILED},
    {"comparisons of floats with nan and inf, and of -0.0 with 0.0",
     "local zero, nan, inf = 0.0, 0.0 / 0.0, 1.0 / 0.0\n"
     "local cnt = 0\n"
     "for i = 1, 10 do\n"
     "  local fi = i * 0.5\n"
     "  if nan < fi then cnt = cnt + 1 end\n"
     "  if nan <= fi then cnt = cnt + 2 end\n"
     "  if nan > fi then cnt = cnt + 4 end\n"
     "  if nan >= fi then cnt = cnt + 8 end\n"
     "  if nan == nan then cnt = cnt + 16 end\n"
     "  if nan ~= nan then cnt = cnt + 32 end\n"
     "  if inf > fi then cnt = cnt + 64 end\n"
     "  if fi < inf then cnt = cnt + 128 end\n"
     "  if -inf == -inf and fi ~= fi then cnt = cnt + 256 end\n"
     "  if fi == 2.5 then cnt = cnt + 512 end\n"
     "  if fi ~= 2.5 then cnt = cnt + 1024 end\n"
     "  if zero == -zero then cnt = cnt + 2048 end\n"
     "  if fi <= 2.5 and fi >= 1.0 or nan ~= 0.0 then cnt = cnt + 4096 end\n"
     "end\n"
     "return cnt",
     COMPILED},
    {"a power on positive, negative, zero, fractional, nan and inf operands, as the interpreter's pow",
     "local zero, nan, inf = 0.0, 0.0 / 0.0, 1.0 / 0.0\n"
     "local p, q, r, s, t, u = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0\n"
     "for i = 1, 30 do\n"
     "  local b = (i - 15) * 0.5\n"
     "  local e = (i % 7) - 3.5\n"
     "  p = p + b ^ 2 + b ^ 3.0\n"
     "  q = q + (b + 0.0) ^ e\n"
     "  r = r + (zero - b) ^ 0.5 + 2 ^ e\n"
     "  s = s + zero ^ e + e ^ zero\n"
     "  t = t + inf ^ e + (-inf) ^ 3 + nan ^ e\n"
     "  u = u + b ^ inf + 1 ^ nan\n"
     "end\n"
     "return p, q, r, s, t, u",
     COMPILED},
    {"a loop that mixes a power with integer operations",
     "local h, w = 0, 0.0\n"
     "for i = 1, 50 do\n"
     "  h = h * 31 + i\n"
     "  w = w + (i ^ 2) * 0.5 + (h & 255) - i // 3 + 2 ^ -i\n"
     "end\n"
     "return h, w",
     COMPILED},
    {"a comparison of an integer with a float, exact as the interpreter's: compiled",
     "local c = 0\n"
     "for i = 1, 10 do if i < 2.5 then c = c + 1 end end\n"
     "return c",
     COMPILED},
    {"a float floor division: the floor of the quotient, as the interpreter's, compiled",
     "local c = 0.0\n"
     "for i = 1, 10 do c = c + (c + i) // 2.0 end\n"
     "return c",
     COMPILED},
    {"a while around an inner for whose limit is a float: the inner for runs compiled too",
     "local s, n, i = 0, 7.5, 0\n"
     "while i < 3 do i = i + 1 for j = 1, n / 2 do s = s + j end end\n"
     "return s",
     COMPILED},
    {"float for loops: a float start with the default step, a negative float step, an integer step with a float start, and a break",
     "local s, t, u, n = 0.0, 0.0, 0.0, 0\n"
     "for x = 0.5, 3 do s = s + x n = n + 1 end\n"
     "for x = 3.0, -1.0, -0.5 do t = t + x end\n"
     "for x = 0.25, 2.5, 1 do u = u + x * x if x > 1.9 then break end end\n"
     "return s, t, u, n",
     COMPILED},
    {"a float loop inside an integer loop, with a float limit from a local and a step of 0.1 (inexact sums)",
     "local lim, acc = 2.0, 0.0\n"
     "for i = 1, 40 do\n"
     "  for x = i * 0.25, lim + i / 8, 0.1 do acc = acc + x * i end\n"
     "  lim = lim + 0.05\n"
     "end\n"
     "return acc, lim",
     COMPILED},
    {"float loops with a nan start or limit: the first test of the interpreter runs the body once, the next test ends the loop",
     "local nan = 0.0 / 0.0\n"
     "local s, t, u = 0, 0, 0\n"
     "for i = 1, 30 do\n"
     "  for x = nan, 2.0 do s = s + 1 end\n"
     "  for x = 1.0, nan do t = t + 1 end\n"
     "  for x = nan, 2.0, -0.5 do u = u + 1 end\n"
     "end\n"
     "return s, t, u",
     COMPILED},
    {"integer loops with float limits: clipped to the integers, a nan limit or one on the wrong side does not run, huge limits break out",
     "local s, n = 0, 0\n"
     "for k = 1, 4 do\n"
     "  for j = 1, 2.5 do s = s + j end\n"
     "  for j = 10, 1.5 do s = s + 100 end\n"
     "  for j = 1, 1e300 do if j > 6 then break end s = s + j end\n"
     "  for j = 5, -1e300, -1 do if j < 2 then break end s = s + 1000 end\n"
     "  for j = 1, 0.0 / 0.0 do s = s + 10000 end\n"
     "  for j = 1, 1e300 do n = n + 1 if j == k then break end end\n"
     "end\n"
     "return s, n",
     COMPILED},
    {"an integer and a float compared exactly beyond 2^53 and 2^63, with nan, inf and -0.0 on either side",
     "local big, f53 = 9007199254740993, 9007199254740992.0\n"
     "local mx, f63 = 9223372036854775807, 9223372036854775808.0\n"
     "local mn = -9223372036854775807 - 1\n"
     "local nan, inf, z, c = 0.0 / 0.0, 1.0 / 0.0, 0, 0\n"
     "for i = 1, 20 do\n"
     "  local k = big + i - 20\n"
     "  if k < f53 then c = c + 1 end\n"
     "  if k <= f53 then c = c + 2 end\n"
     "  if k > f53 then c = c + 4 end\n"
     "  if k >= f53 then c = c + 8 end\n"
     "  if k == f53 then c = c + 16 end\n"
     "  if k ~= f53 then c = c + 32 end\n"
     "  if f53 < k then c = c + 64 end\n"
     "  if nan < k or k < nan or nan == k or nan >= k or k <= nan then c = c + 128 end\n"
     "  if inf > k and -inf < k and k ~= inf then c = c + 256 end\n"
     "  if mx < f63 and mn == -f63 and mx ~= f63 then c = c + 512 end\n"
     "  if mx >= f63 or mn > -f63 then c = c + 1024 end\n"
     "  if z == -0.0 and -0.0 == z then c = c + 2048 end\n"
     "  if (i - 10.5) < k then c = c + 4096 end\n"
     "end\n"
     "return c",
     COMPILED},
    {"mixed comparisons with the operators > >= ~= and the operands on both sides, in a while",
     "local a, t, n = 3, 0.0, 0\n"
     "while t < 5.5 do\n"
     "  t = t + 0.75\n"
     "  n = n + 1\n"
     "  if a > t and a >= t and not (a == t) and a ~= t and 2.5 < a + 0.0 then a = a + 1 end\n"
     "end\n"
     "return a, t, n",
     COMPILED},
    {"floor division and modulo of floats and of mixed operands, with negative, zero, nan and inf divisors, as the interpreter's",
     "local q, r, n1, n2 = 0.0, 0.0, 0.0, 0.0\n"
     "for i = 1, 40 do\n"
     "  local x = i * 0.7 - 9.0\n"
     "  q = q + x // 2 + x // -0.5 + i // 0.0 + (-x) // 3\n"
     "  r = r + x % 2 + x % -0.75 + (-x) % 3 + i % 0.0 + (3 - i) % 2.5\n"
     "  n1 = (-0.0) // 1.0 + n1 * 0.0\n"
     "  n2 = (-0.0) % 1.0 + n2 * 0.0\n"
     "end\n"
     "return q, r, n1, n2",
     COMPILED},
    {"a float loop that divides an integer by zero: the deopt of the statement, with the float accumulator written back",
     "local d, s = 4, 0.0\n"
     "for x = 1.0, 9.0 do d = d - 1 s = s + 100 // d end\n"
     "return s",
     DEOPT},
    {"a numeric for whose start is an integer on some entries and a float on others: code of one kind is not entered with the other",
     "local s = 0\n"
     "for k = 1, 6 do\n"
     "  local a = (k < 4) and 0.5 or 1\n"
     "  for x = a, 3 do s = s + x end\n"
     "end\n"
     "return s",
     ANY},
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
static bool gen_float = false;  // the batch of float programs (gen_float_program)

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

// The generated float programs: float locals x, y, z (assigned floats only), an integer local n and the loop variable i. The integers
// meet floats in arithmetic, `/` and `^` (which give floats), and a comparison is between two floats (the integer against a float is
// refused, see the cases), so every loop is in the subset and must compile. The divisors of the integer operations are constants that
// are not zero, so no deopt.
static std::string gen_iexpr(Rng& r, int depth) {
  if (depth <= 0 || r.pick(3) == 0) {
    switch (r.pick(3)) {
      case 0: return r.pick(2) ? "i" : "n";
      case 1: return std::to_string(r.pick(20) - 10);
      default: return "9223372036854775807";
    }
  }
  switch (r.pick(5)) {
    case 0: return "(" + gen_iexpr(r, depth - 1) + " + " + gen_iexpr(r, depth - 1) + ")";
    case 1: return "(" + gen_iexpr(r, depth - 1) + " * " + gen_iexpr(r, depth - 1) + ")";
    case 2: {
      static const char* divisors[] = {"-1", "2", "-3", "7", "9223372036854775807"};
      return "(" + gen_iexpr(r, depth - 1) + " // " + divisors[r.pick(5)] + ")";
    }
    case 3: return "(-(" + gen_iexpr(r, depth - 1) + "))";
    default: return "(" + gen_iexpr(r, depth - 1) + " % 5)";
  }
}

static std::string gen_fexpr(Rng& r, int depth) {
  static const char* leaves[] = {"x", "y", "z", "0.0", "-0.0", "0.5", "-2.25", "3.0", "1e300", "-1e-300", "7.75", "1.0"};
  static const char* ops[] = {" + ", " - ", " * ", " / ", " ^ "};
  if (depth <= 0 || r.pick(3) == 0) return leaves[r.pick(12)];
  switch (r.pick(7)) {
    case 0: case 1: case 2: case 3: return "(" + gen_fexpr(r, depth - 1) + ops[r.pick(5)] + gen_fexpr(r, depth - 1) + ")";
    case 4: return "(-(" + gen_fexpr(r, depth - 1) + "))";
    case 5: return "(" + gen_iexpr(r, 2) + ops[r.pick(5)] + gen_fexpr(r, depth - 1) + ")";  // an integer and a float
    default: return "(" + gen_iexpr(r, 2) + (r.pick(2) ? " / " : " ^ ") + gen_iexpr(r, 2) + ")";  // integers, a float result
  }
}

static std::string gen_fcond(Rng& r, int depth) {
  static const char* ops[] = {"<", "<=", ">", ">=", "==", "~="};
  if (depth > 0 && r.pick(4) == 0) {
    switch (r.pick(3)) {
      case 0: return "(" + gen_fcond(r, depth - 1) + " and " + gen_fcond(r, depth - 1) + ")";
      case 1: return "(" + gen_fcond(r, depth - 1) + " or " + gen_fcond(r, depth - 1) + ")";
      default: return "(not (" + gen_fcond(r, depth - 1) + "))";
    }
  }
  return gen_fexpr(r, 2) + " " + ops[r.pick(6)] + " " + gen_fexpr(r, 2);
}

static std::string gen_fstmt(Rng& r, int depth, int& wcount) {
  switch (depth > 0 ? r.pick(6) : r.pick(4)) {
    case 0: return "x = " + gen_fexpr(r, 3) + "\n";
    case 1: return "y = " + gen_fexpr(r, 3) + " z = z + " + gen_fexpr(r, 2) + "\n";
    case 2: return "n = n + " + gen_iexpr(r, 2) + "\n";
    case 3: {
      std::string t = "t" + std::to_string(wcount);
      ++wcount;
      return "local " + t + " = " + gen_fexpr(r, 2) + " x = x + " + t + "\n";
    }
    case 4:
      return "if " + gen_fcond(r, 2) + " then " + gen_fstmt(r, depth - 1, wcount) + " else " + gen_fstmt(r, depth - 1, wcount) + " end\n";
    default: {
      std::string w = "w" + std::to_string(wcount);
      ++wcount;
      return "do local " + w + " = 0 while " + w + " < " + std::to_string(1 + r.pick(4)) + " do " + w + " = " + w + " + 1 " +
             gen_fstmt(r, depth - 1, wcount) + " end end\n";
    }
  }
}

static std::string gen_float_program(Rng& r) {
  static const char* init[] = {"0.5", "-0.0", "2.25", "-3.0", "0.0", "1e300"};
  int wcount = 0;
  std::string body;
  int n = 2 + r.pick(3);
  for (int k = 0; k < n; ++k) body += gen_fstmt(r, 2, wcount);
  std::string loop = "for i = 1, " + std::to_string(3 + r.pick(30)) + " do\n" + body + "end\n";
  if (r.pick(2)) loop = "for i = 1, " + std::to_string(2 + r.pick(10)) + " do\n" + "for j = 1, 3 do\n" + body + "end\nend\n";
  return "local x, y, z = " + std::string(init[r.pick(6)]) + ", " + init[r.pick(6)] + ", " + init[r.pick(6)] + "\nlocal n = 0\n" +
         loop + "return x, y, z, n";
}

// The batch of mixed programs (gen_mixed_program): integer and float locals in one loop, the comparisons and the arithmetic of an
// integer with a float (also // and %), float loops with constant steps whose starts and limits are bounded or nan, and integer loops
// with float limits. Every one is in the subset: no bitwise operator on a float, and no integer division by a constant that is zero.
static bool gen_mixed = false;
static bool mixed_in_float = false;  // generating the body of a float loop, whose variable t is in scope

static std::string gen_mint(Rng& r, int depth) {
  static const char* leaves[] = {"a", "b", "i"};
  if (depth <= 0 || r.pick(3) == 0) {
    switch (r.pick(3)) {
      case 0: return leaves[r.pick(3)];
      case 1: return std::to_string(r.pick(20) - 10);
      default: return "9007199254740993";
    }
  }
  static const char* ops[] = {" + ", " - ", " * "};
  switch (r.pick(4)) {
    case 0:
    case 1: {
      std::string l = gen_mint(r, depth - 1);
      std::string op = ops[r.pick(3)];
      return "(" + l + op + gen_mint(r, depth - 1) + ")";
    }
    case 2: {
      std::string l = gen_mint(r, depth - 1);
      std::string op = r.pick(2) ? " // " : " % ";
      return "(" + l + op + (r.pick(2) ? "-3" : "7") + ")";
    }
    default: return "(-(" + gen_mint(r, depth - 1) + "))";
  }
}

static std::string gen_mflt(Rng& r, int depth) {
  static const char* leaves[] = {"x", "y", "0.5", "-2.25", "3.0", "-0.0", "1e300", "7.75", "nan", "inf"};
  static const char* ops[] = {" + ", " - ", " * ", " / ", " // ", " % ", " ^ "};
  if (depth <= 0 || r.pick(3) == 0) {
    if (mixed_in_float && r.pick(4) == 0) return "t";
    return leaves[r.pick(10)];
  }
  switch (r.pick(4)) {
    case 0:
    case 1: {
      std::string l = gen_mflt(r, depth - 1);
      std::string op = ops[r.pick(7)];
      return "(" + l + op + gen_mflt(r, depth - 1) + ")";
    }
    case 2: {  // an integer and a float
      std::string l = gen_mint(r, 2);
      std::string op = ops[r.pick(7)];
      return "(" + l + op + gen_mflt(r, depth - 1) + ")";
    }
    default: return "(-(" + gen_mflt(r, depth - 1) + "))";
  }
}

static std::string gen_mcond(Rng& r) {
  static const char* ops[] = {"<", "<=", ">", ">=", "==", "~="};
  std::string l = r.pick(2) ? gen_mint(r, 2) : gen_mflt(r, 2);
  std::string op = ops[r.pick(6)];
  std::string rhs = r.pick(2) ? gen_mint(r, 2) : gen_mflt(r, 2);
  return l + " " + op + " " + rhs;
}

static std::string gen_mstmt(Rng& r, int depth, int& wcount) {
  switch (depth > 0 ? r.pick(8) : r.pick(3)) {
    case 0: return "a = " + gen_mint(r, 3) + "\n";
    case 1: return "x = " + gen_mflt(r, 3) + "\n";
    case 2: {
      std::string bi = gen_mint(r, 2);
      std::string yf = gen_mflt(r, 2);
      return "b = b + " + bi + " y = y + " + yf + "\n";
    }
    case 3: {
      std::string c = gen_mcond(r);
      std::string th = gen_mstmt(r, depth - 1, wcount);
      std::string el = gen_mstmt(r, depth - 1, wcount);
      return "if " + c + " then " + th + " else " + el + " end\n";
    }
    case 4: {  // a float local of a block, added to y
      std::string w = "w" + std::to_string(wcount++);
      return "do local " + w + " = " + gen_mflt(r, 2) + " y = y + " + w + " end\n";
    }
    case 5: {  // an integer loop with a float limit (nan, or a small number of iterations)
      std::string j = "j" + std::to_string(wcount++);
      std::string bound = gen_mflt(r, 2);
      std::string body = gen_mstmt(r, depth - 1, wcount);
      return "for " + j + " = 1, (" + bound + ") * 0.0 + " + std::to_string(1 + r.pick(3)) + ".0 do " + body + "end\n";
    }
    case 6: {  // a float loop with a constant step; its start and limit are bounded (or nan), its body is the same kind of statements
      if (mixed_in_float) return "x = " + gen_mflt(r, 3) + "\n";
      static const char* steps[] = {"0.5", "-0.25", "1", "-1", "2.0"};
      static const char* starts[] = {"0.5", "-1.0", "2.0"};
      static const char* limits[] = {"3.0", "-2.0", "0.5"};
      mixed_in_float = false;
      std::string lo = "(" + gen_mflt(r, 1) + ") * 0.0 + " + starts[r.pick(3)];
      std::string hi = "(" + gen_mflt(r, 1) + ") * 0.0 + " + limits[r.pick(3)];
      mixed_in_float = true;
      std::string body = gen_mstmt(r, depth - 1, wcount);
      mixed_in_float = false;
      return "for t = " + lo + ", " + hi + ", " + steps[r.pick(5)] + " do\n" + body + "end\n";
    }
    default: {  // a while with an integer counter
      std::string w = "w" + std::to_string(wcount++);
      std::string bound = std::to_string(1 + r.pick(4));
      return "do local " + w + " = 0 while " + w + " < " + bound + " do " + w + " = " + w + " + 1 " +
             gen_mstmt(r, depth - 1, wcount) + " end end\n";
    }
  }
}

static std::string gen_mixed_program(Rng& r) {
  static const char* ints[] = {"0", "7", "-3"};
  static const char* flts[] = {"0.5", "-0.0", "2.25", "-3.0", "0.0", "1e300"};
  int wcount = 0;
  std::string body;
  int n = 2 + r.pick(3);
  for (int k = 0; k < n; ++k) body += gen_mstmt(r, 2, wcount);
  std::string upper = std::to_string(3 + r.pick(20));
  std::string loop = "for i = 1, " + upper + " do\n" + body + "end\n";
  std::string a0 = ints[r.pick(3)], b0 = ints[r.pick(3)], x0 = flts[r.pick(6)], y0 = flts[r.pick(6)];
  return "local a, b = " + a0 + ", " + b0 + "\n" + "local x, y = " + x0 + ", " + y0 + "\n" + "local nan, inf = 0.0 / 0.0, 1.0 / 0.0\n" +
         loop + "return a, b, x, y";
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
        case MIXED: CHECK(st.jit_compiled >= 1 && st.jit_entries >= 1 && st.jit_guard_misses >= 1); break;
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
  // the bitwise operators and the shifts; the third has floats (gen_float_program); the fourth has integers and floats mixed, float
  // loops and integer loops with float limits (gen_mixed_program); the first is the same as before them.
  std::printf("-- generated loops\n");
  unsigned long long entries = 0, compiled = 0;
  int gen_fail = 0;
  const int kPrograms = 300;
  static const char* batch_names[] = {"arithmetic", "bitwise", "float", "mixed"};
  for (int batch = 0; batch < 4; ++batch) {
    gen_bits = batch == 1;
    gen_float = batch == 2;
    gen_mixed = batch == 3;
    Rng r = batch == 0   ? Rng{0x9E3779B97F4A7C15ULL}
            : batch == 1 ? Rng{0x2545F4914F6CDD1DULL}
            : batch == 2 ? Rng{0x51AF2C8E0B3D96A7ULL}
                         : Rng{0x7A3C5E91D2B4F687ULL};
    unsigned long long b_entries = 0, b_compiled = 0;
    int b_fail = 0;
    for (int k = 0; k < kPrograms; ++k) {
      std::string code = gen_mixed ? gen_mixed_program(r) : gen_float ? gen_float_program(r) : gen_program(r);
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
      bool same = gen_mixed ? without_nan_sign(got) == without_nan_sign(want) : got == want;
      bool ok = same && S.stats.jit_bailouts == S.stats.jit_guard_misses;
      if (avail) ok = ok && S.stats.jit_refused == 0;
      if (!ok) {
        ++b_fail;
        std::printf("FAIL generated program %d (%s):\n%s\n  got %s\n  want %s\n", k, batch_names[batch],
                    code.c_str(), got.c_str(), want.c_str());
      }
    }
    gen_fail += b_fail;
    entries += b_entries;
    compiled += b_compiled;
    if (avail) CHECK(b_compiled >= static_cast<unsigned long long>(kPrograms) && b_entries >= static_cast<unsigned long long>(kPrograms));
    std::printf("ok   %d %s generated programs: %llu loops compiled, %llu takeovers%s\n", kPrograms, batch_names[batch], b_compiled,
                b_entries, b_fail ? " (FAILURES)" : "");
  }
  gen_bits = false;
  gen_float = false;
  gen_mixed = false;
  CHECK(gen_fail == 0);

  if (failures) std::printf("%d of %d check(s) failed\n", failures, checks);
  else std::printf("all %d checks passed\n", checks);
  return failures ? 1 : 0;
}
