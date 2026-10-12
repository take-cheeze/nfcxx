// nfcuop stages 1 and 2: interning, the interpreter, patterns, graph_rewrite, the symbolic simplifier, and a
// differential check of the simplifier against the interpreter on random expressions.
#include <cmath>
#include <cstdio>
#include <functional>
#include <map>
#include <cstdlib>
#include <string>

#include "nfcuop.hpp"

using namespace nfcuop;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
#define CHECK_THROWS(expr)                                                 \
  do {                                                                     \
    checks++;                                                              \
    bool threw_ = false;                                                   \
    try { (void)(expr); } catch (const Error&) { threw_ = true; }          \
    if (!threw_) { failed++; std::printf("FAIL %s:%d: no Error from %s\n", __FILE__, __LINE__, #expr); } \
  } while (0)

static Scalar I32(int64_t v) { return Scalar::from_int(DType::Int32, v); }
static Scalar F32(double v) { return Scalar::from_double(DType::Float32, v); }
static const UOp* rw(Graph& g, const UOp* u) { return graph_rewrite(g, symbolic(), u); }

static void stage1() {
  Graph g;
  const DType i32 = DType::Int32, f32 = DType::Float32;
  // interning
  const UOp* x = g.var("x", i32);
  CHECK(x == g.var("x", i32));
  CHECK(x != g.var("y", i32));
  CHECK(x != g.var("x", DType::Int64));
  CHECK(g.iconst(i32, 3) == g.iconst(i32, 3));
  CHECK(g.iconst(i32, 3) != g.iconst(DType::Int64, 3));
  CHECK(g.fconst(f32, 0.0) != g.fconst(f32, -0.0));  // bitwise
  CHECK(g.add(x, g.iconst(i32, 1)) == g.add(x, g.iconst(i32, 1)));
  CHECK(g.add(x, g.iconst(i32, 1)) != g.add(g.iconst(i32, 1), x));  // structure, not meaning
  CHECK(g.iconst(i32, 4294967296LL + 5) == g.iconst(i32, 5));       // wrapped to the dtype before interning
  size_t n = g.size();
  g.add(x, g.iconst(i32, 1));
  CHECK(g.size() == n);
  CHECK(x->id < g.add(x, x)->id);

  // type checks
  const UOp* y = g.var("y", DType::Int64);
  CHECK_THROWS(g.add(x, y));
  CHECK_THROWS(g.sqrt(x));
  CHECK_THROWS(g.fdiv(x, x));
  CHECK_THROWS(g.idiv(g.fconst(f32, 1), g.fconst(f32, 2)));
  CHECK_THROWS(g.where(x, x, x));
  CHECK_THROWS(g.where(g.cmplt(x, x), x, y));
  CHECK_THROWS(g.neg(g.cmplt(x, x)));
  CHECK_THROWS(g.alu(Op::Add, {x}));
  CHECK_THROWS(g.alu(Op::Const, {}));
  CHECK(g.cmplt(x, x)->dtype == DType::Bool);
  CHECK(g.cast(x, f32)->dtype == f32);

  // evaluation
  std::map<std::string, Scalar> env{{"x", I32(7)}};
  CHECK(evaluate(g.add(x, g.iconst(i32, 5)), env) == I32(12));
  CHECK(evaluate(g.add(g.iconst(i32, 2147483647), g.iconst(i32, 1))) == I32(-2147483648LL));
  CHECK(evaluate(g.mul(g.iconst(i32, 65536), g.iconst(i32, 65536))) == I32(0));
  CHECK(evaluate(g.idiv(g.iconst(i32, -7), g.iconst(i32, 2))) == I32(-3));
  CHECK(evaluate(g.mod(g.iconst(i32, -7), g.iconst(i32, 2))) == I32(-1));
  CHECK(evaluate(g.idiv(g.iconst(i32, -2147483648LL), g.iconst(i32, -1))) == I32(-2147483648LL));
  CHECK(evaluate(g.mod(g.iconst(i32, -2147483648LL), g.iconst(i32, -1))) == I32(0));
  CHECK_THROWS(evaluate(g.idiv(x, g.iconst(i32, 0)), env));
  CHECK_THROWS(evaluate(x));                                            // unbound
  CHECK_THROWS(evaluate(x, {{"x", Scalar::from_int(DType::Int64, 1)}}));  // wrong dtype
  CHECK(evaluate(g.neg(g.iconst(i32, -2147483648LL))) == I32(-2147483648LL));
  CHECK(evaluate(g.max(g.iconst(i32, 3), g.iconst(i32, 9))) == I32(9));
  CHECK(evaluate(g.band(g.iconst(i32, 12), g.iconst(i32, 10))) == I32(8));
  CHECK(evaluate(g.bor(g.iconst(i32, 12), g.iconst(i32, 10))) == I32(14));
  CHECK(evaluate(g.bxor(g.iconst(i32, 12), g.iconst(i32, 10))) == I32(6));
  CHECK(evaluate(g.cmplt(g.iconst(i32, 1), g.iconst(i32, 2))) == Scalar::from_int(DType::Bool, 1));
  CHECK(evaluate(g.where(g.cmplt(x, g.iconst(i32, 10)), g.iconst(i32, 100), g.iconst(i32, 200)), env) == I32(100));
  // floats: float32 is rounded at every node
  const UOp* a = g.fconst(f32, 0.1), *b = g.fconst(f32, 0.2);
  Scalar s = evaluate(g.add(a, b));
  CHECK(s.dtype == f32 && s.f == static_cast<double>(0.1f + 0.2f));
  CHECK(evaluate(g.sqrt(g.fconst(DType::Float64, 2.0))).f == std::sqrt(2.0));
  CHECK(evaluate(g.fdiv(g.fconst(f32, 1), g.fconst(f32, 0))).f > 1e300);  // inf, not an error
  CHECK(evaluate(g.cmpne(g.fdiv(g.fconst(f32, 0), g.fconst(f32, 0)), g.fconst(f32, 0))) == Scalar::from_int(DType::Bool, 1));
  CHECK(evaluate(g.max(g.fconst(f32, 1), g.fconst(f32, 3))) == F32(3));
  // casts
  CHECK(evaluate(g.cast(g.fconst(f32, -2.7), i32)) == I32(-2));
  CHECK(evaluate(g.cast(g.fconst(f32, 3e10), i32)) == I32(2147483647));
  CHECK(evaluate(g.cast(g.fconst(f32, -3e10), i32)) == I32(-2147483648LL));
  CHECK(evaluate(g.cast(g.fdiv(g.fconst(f32, 0), g.fconst(f32, 0)), i32)) == I32(0));
  CHECK(evaluate(g.cast(g.iconst(i32, 5), f32)) == F32(5));
  CHECK(evaluate(g.cast(g.iconst(DType::Int64, 4294967297LL), i32)) == I32(1));
  CHECK(evaluate(g.cast(g.iconst(i32, 7), DType::Bool)) == Scalar::from_int(DType::Bool, 1));
  CHECK(evaluate(g.cast(g.fconst(f32, 0.5), DType::Bool)) == Scalar::from_int(DType::Bool, 1));
  // sharing: a node used twice is one node in the sort and evaluated once
  const UOp* sq = g.mul(g.add(x, g.iconst(i32, 1)), g.add(x, g.iconst(i32, 1)));
  CHECK(toposort(sq).size() == 4);
  CHECK(evaluate(sq, env) == I32(64));
  // dump is a golden text
  const UOp* e = g.where(g.cmplt(x, g.iconst(i32, 10)), g.mul(x, g.iconst(i32, 2)), g.neg(x));
  const char* golden =
      "  0 VAR    int32   () x\n"
      "  1 CONST  int32   () 10\n"
      "  2 CMPLT  bool    (0, 1)\n"
      "  3 CONST  int32   () 2\n"
      "  4 MUL    int32   (0, 3)\n"
      "  5 NEG    int32   (0)\n"
      "  6 WHERE  int32   (2, 4, 5)\n";
  CHECK(dump(e) == golden);
  if (dump(e) != golden) std::printf("%s", dump(e).c_str());
}

static void stage2() {
  Graph g;
  const DType i32 = DType::Int32, f32 = DType::Float32;
  const UOp* x = g.var("x", i32);
  const UOp* y = g.var("y", i32);
  auto k = [&](int64_t v) { return g.iconst(i32, v); };

  // patterns and captures
  {
    Match m;
    const UOp* e = g.add(x, k(3));
    CHECK(Pat::op(Op::Add, {Pat::any("a"), Pat::cvar("c")}).matches(e, m));
    CHECK(m["a"] == x && m["c"] == k(3));
    Match m2;  // commutative: the sources are tried in both orders
    CHECK(Pat::op(Op::Add, {Pat::cvar("c"), Pat::any("a")}).matches(e, m2));
    CHECK(m2["a"] == x && m2["c"] == k(3));
    Match m3;
    CHECK(!Pat::op(Op::Add, {Pat::cvar("c"), Pat::any("a")}).ordered().matches(e, m3));
    CHECK(m3.b_.empty());
    Match m4;
    CHECK(!Pat::op(Op::Sub, {Pat::any(), Pat::any()}).matches(e, m4));
    CHECK(!Pat::op(Op::Add, {Pat::any("a"), Pat::any("a")}).matches(e, m4));  // same name needs the same node
    CHECK(Pat::op(Op::Add, {Pat::any("a"), Pat::any("a")}).matches(g.add(x, x), m4));
    CHECK(Pat::op(Op::Add).matches(e, m4));                                     // any sources
    CHECK(!Pat::any().with_dtype(DType::Float32).matches(e, m4));
    CHECK(Pat::cval(3).matches(k(3), m4) && !Pat::cval(3).matches(k(4), m4));
    CHECK(Pat::cval(2).matches(g.fconst(f32, 2.0), m4));
    CHECK_THROWS(m4["nothing"]);
    Match m5;  // a failed commutative attempt leaves no bindings behind
    CHECK(!Pat::op(Op::Add, {Pat::any("p"), Pat::cval(9)}).matches(e, m5));
    CHECK(m5.b_.empty());
  }

  // simplifications: the result is the very node, thanks to interning
  CHECK(rw(g, g.add(x, k(0))) == x);
  CHECK(rw(g, g.add(k(0), x)) == x);
  CHECK(rw(g, g.mul(g.add(x, k(0)), k(1))) == x);
  CHECK(rw(g, g.sub(x, k(0))) == x);
  CHECK(rw(g, g.sub(k(0), x)) == g.sub(k(0), x));          // 0-x is not x
  CHECK(rw(g, g.mul(x, k(0))) == k(0));
  CHECK(rw(g, g.sub(x, x)) == k(0));
  CHECK(rw(g, g.bxor(x, x)) == k(0));
  CHECK(rw(g, g.band(x, x)) == x);
  CHECK(rw(g, g.bor(x, x)) == x);
  CHECK(rw(g, g.max(x, x)) == x);
  CHECK(rw(g, g.band(x, k(0))) == k(0));
  CHECK(rw(g, g.band(x, k(1))) == g.band(x, k(1)));       // a mask, not an identity
  CHECK(rw(g, g.idiv(x, k(1))) == x);
  CHECK(rw(g, g.mod(x, k(1))) == k(0));
  CHECK(rw(g, g.neg(g.neg(x))) == x);
  CHECK(rw(g, g.cmplt(x, x)) == g.iconst(DType::Bool, 0));
  CHECK(rw(g, g.cmpne(x, x)) == g.iconst(DType::Bool, 0));
  CHECK(rw(g, g.cast(x, i32)) == x);
  CHECK(rw(g, g.cast(x, DType::Int64)) == g.cast(x, DType::Int64));
  // constants: fold, move right, combine
  CHECK(rw(g, g.add(g.mul(k(2), k(3)), x)) == g.add(x, k(6)));
  CHECK(rw(g, g.add(k(5), x)) == g.add(x, k(5)));
  CHECK(rw(g, g.add(g.add(x, k(1)), k(2))) == g.add(x, k(3)));
  CHECK(rw(g, g.add(g.add(k(1), x), k(2))) == g.add(x, k(3)));
  CHECK(rw(g, g.mul(g.mul(x, k(3)), k(4))) == g.mul(x, k(12)));
  CHECK(rw(g, g.add(g.add(x, k(1)), k(-1))) == x);
  CHECK(rw(g, g.add(k(2147483647), k(1))) == k(-2147483648LL));
  CHECK(rw(g, g.cast(g.fconst(f32, 2.9), i32)) == k(2));
  CHECK(rw(g, g.idiv(x, k(0))) == g.idiv(x, k(0)));        // kept, fails only when evaluated
  CHECK(rw(g, g.idiv(k(1), k(0))) == g.idiv(k(1), k(0)));
  // where
  const UOp* t = g.iconst(DType::Bool, 1), *f = g.iconst(DType::Bool, 0);
  CHECK(rw(g, g.where(t, x, y)) == x);
  CHECK(rw(g, g.where(f, x, y)) == y);
  CHECK(rw(g, g.where(g.cmplt(x, y), x, x)) == x);
  CHECK(rw(g, g.where(g.cmplt(x, k(0)), g.add(x, k(0)), x)) == x);  // arms become equal after rewriting
  const UOp* p = g.cmplt(x, y);
  CHECK(rw(g, g.band(p, t)) == p);
  CHECK(rw(g, g.bor(p, t)) == t);
  CHECK(rw(g, g.bor(p, f)) == p);
  // floats: only the safe identities
  const UOp* a = g.var("a", f32);
  CHECK(rw(g, g.add(a, g.fconst(f32, 0))) == a);
  CHECK(rw(g, g.mul(a, g.fconst(f32, 1))) == a);
  CHECK(rw(g, g.fdiv(a, g.fconst(f32, 1))) == a);
  CHECK(rw(g, g.mul(a, g.fconst(f32, 0))) == g.mul(a, g.fconst(f32, 0)));   // a may be inf or NaN
  CHECK(rw(g, g.sub(a, a)) == g.sub(a, a));
  CHECK(rw(g, g.cmpne(a, a)) == g.cmpne(a, a));                             // true for NaN
  CHECK(rw(g, g.cmplt(a, a)) == g.iconst(DType::Bool, 0));
  CHECK(rw(g, g.add(g.add(a, g.fconst(f32, 0.1)), g.fconst(f32, 0.2))) == g.add(g.add(a, g.fconst(f32, 0.1)), g.fconst(f32, 0.2)));
  CHECK(rw(g, g.add(g.fconst(f32, 1), g.fconst(f32, 2))) == g.fconst(f32, 3));

  // custom rules, labels, extend and the step limit
  {
    PatternMatcher pm;
    int hits = 0;
    pm.add(Pat::op(Op::Mul, {Pat::any("a"), Pat::cval(2)}), [&](Graph& gg, const Match& m) {
      hits++;
      return gg.add(m["a"], m["a"]);
    }, "x*2 -> x+x");
    pm.extend(symbolic());
    CHECK(pm.size() == symbolic().size() + 1);
    const UOp* r = graph_rewrite(g, pm, g.mul(g.mul(x, k(2)), k(1)));
    CHECK(r == g.add(x, x));
    CHECK(hits == 1);
    const UOp* ua = g.var("osc_a", i32), *ub = g.var("osc_b", i32);
    PatternMatcher osc;  // a -> b and b -> a
    osc.add(Pat::op(Op::Var, "self"), [&](Graph&, const Match& m) { return m["self"] == ua ? ub : ua; });
    CHECK_THROWS(graph_rewrite(g, osc, ua));
    PatternMatcher grow;  // x -> x + 1 -> (x + 1) + 1 ... never ends
    grow.add(Pat::op(Op::Var, "self"), [](Graph& gg, const Match& m) { return gg.add(m["self"], gg.iconst(m["self"]->dtype, 1)); });
    CHECK_THROWS(graph_rewrite(g, grow, ua, 50));
  }

  // evaluate(rewrite(e)) == evaluate(e) on random expressions
  unsigned long long seed = 12345;
  auto rnd = [&](unsigned n) { seed = seed * 6364136223846793005ull + 1442695040888963407ull; return static_cast<unsigned>((seed >> 33) % n); };
  struct Gen {
    Graph& g; std::function<unsigned(unsigned)> rnd;
    const UOp *x, *y;
    const UOp* leaf() {
      switch (rnd(7)) {
        case 0: return x;
        case 1: return y;
        default: return g.iconst(DType::Int32, static_cast<int>(rnd(7)) - 2);   // -2..4: hits 0, 1, -1
      }
    }
    const UOp* boolean(int d) {
      if (d <= 0 || rnd(5) == 0) return rnd(2) ? g.cmplt(leaf(), leaf()) : g.cmpne(leaf(), leaf());
      switch (rnd(4)) {
        case 0: return g.band(boolean(d - 1), boolean(d - 1));
        case 1: return g.bor(boolean(d - 1), boolean(d - 1));
        case 2: return g.bxor(boolean(d - 1), boolean(d - 1));
        default: return g.cmplt(num(d - 1), num(d - 1));
      }
    }
    const UOp* num(int d) {
      if (d <= 0 || rnd(6) == 0) return leaf();
      switch (rnd(12)) {
        case 0: return g.add(num(d - 1), num(d - 1));
        case 1: return g.sub(num(d - 1), num(d - 1));
        case 2: return g.mul(num(d - 1), num(d - 1));
        case 3: return g.max(num(d - 1), num(d - 1));
        case 4: return g.band(num(d - 1), num(d - 1));
        case 5: return g.bor(num(d - 1), num(d - 1));
        case 6: return g.bxor(num(d - 1), num(d - 1));
        case 7: return g.neg(num(d - 1));
        case 8: return g.where(boolean(d - 1), num(d - 1), num(d - 1));
        case 9: return g.idiv(num(d - 1), g.iconst(DType::Int32, 1 + rnd(3)));
        case 10: return g.mod(num(d - 1), g.iconst(DType::Int32, 1 + rnd(3)));
        default: return g.cast(g.cast(num(d - 1), DType::Float32), DType::Int32);
      }
    }
  } gen{g, rnd, x, y};
  int compared = 0, shrank = 0;
  for (int t2 = 0; t2 < 400; t2++) {
    const UOp* e = gen.num(5);
    const UOp* s = rw(g, e);
    CHECK(rw(g, s) == s);  // idempotent
    if (toposort(s).size() < toposort(e).size()) shrank++;
    for (int vx : {-3, -1, 0, 1, 2, 7, 2147483647}) for (int vy : {-2, 0, 1, 5, -2147483647 - 1}) {
      std::map<std::string, Scalar> env{{"x", I32(vx)}, {"y", I32(vy)}};
      Scalar want = evaluate(e, env), got = evaluate(s, env);
      compared++;
      CHECK(want == got);
      if (want != got) std::printf("  e:\n%s  s:\n%s  x=%d y=%d\n", dump(e).c_str(), dump(s).c_str(), vx, vy);
    }
  }
  std::printf("  differential: %d comparisons, %d of 400 expressions smaller after rewriting\n", compared, shrank);
  CHECK(shrank > 50);
}

int main() {
  stage1();
  stage2();
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
