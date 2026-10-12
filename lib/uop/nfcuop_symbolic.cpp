// nfcuop stage 2: the symbolic simplifier. See nfcuop.hpp for what it promises.
#include "nfcuop.hpp"

namespace nfcuop {

namespace {

const UOp* zero(Graph& g, DType d) { return g.constant(Scalar::from_int(d, 0)); }

PatternMatcher build() {
  PatternMatcher pm;
  using P = Pat;
  auto ordered = [](P p) { p.ordered(); return p; };
  auto X = [] { return P::any("x"); };

  // Constant folding: an ALU node or a Cast whose sources are all constants.
  pm.add(P::any("x"), [](Graph& g, const Match& m) -> const UOp* {
    const UOp* x = m["x"];
    if (x->src.empty() || !(is_alu(x->op) || x->op == Op::Cast)) return nullptr;
    std::vector<Scalar> args;
    for (const UOp* s : x->src) {
      if (!s->is_const()) return nullptr;
      args.push_back(s->value);
    }
    try {
      return g.constant(eval_op(x->op, x->dtype, args));
    } catch (const Error&) {
      return nullptr;  // an integer division by zero stays in the graph and fails when it is evaluated
    }
  }, "fold");

  // Constants to the right of a commutative op.
  for (Op op : {Op::Add, Op::Mul, Op::Max, Op::CmpNe, Op::And, Op::Or, Op::Xor})
    pm.add(ordered(P::op(op, {P::cvar("c"), P::any("x")}, "self")),
           [](Graph& g, const Match& m) { return g.rebuild(m["self"], {m["x"], m["c"]}); }, "canon");

  auto keep_x = [](Graph&, const Match& m) { return m["x"]; };
  auto zero_of_x = [](Graph& g, const Match& m) { return zero(g, m["x"]->dtype); };
  auto int_zero = [](Graph& g, const Match& m) -> const UOp* {  // exact for ints and bool only: 0 * inf is NaN
    return is_float(m["x"]->dtype) ? nullptr : zero(g, m["x"]->dtype);
  };

  pm.add(P::op(Op::Add, {X(), P::cval(0)}), keep_x, "x+0");
  pm.add(ordered(P::op(Op::Sub, {X(), P::cval(0)})), keep_x, "x-0");
  pm.add(P::op(Op::Mul, {X(), P::cval(1)}), keep_x, "x*1");
  pm.add(P::op(Op::Mul, {X(), P::cval(0)}), int_zero, "x*0");
  pm.add(ordered(P::op(Op::IDiv, {X(), P::cval(1)})), keep_x, "x/1");
  pm.add(ordered(P::op(Op::FDiv, {X(), P::cval(1)})), keep_x, "x/1.0");
  pm.add(ordered(P::op(Op::Mod, {X(), P::cval(1)})), zero_of_x, "x%1");
  pm.add(P::op(Op::Or, {X(), P::cval(0)}), keep_x, "x|0");
  pm.add(P::op(Op::Xor, {X(), P::cval(0)}), keep_x, "x^0");
  pm.add(P::op(Op::And, {X(), P::cval(0)}), zero_of_x, "x&0");
  pm.add(P::op(Op::And, {X(), P::cval(1)}), [](Graph&, const Match& m) -> const UOp* {  // x & true; for ints 1 is a mask
    return m["x"]->dtype == DType::Bool ? m["x"] : nullptr;
  }, "x&true");
  pm.add(P::op(Op::Or, {X(), P::cval(1)}), [](Graph& g, const Match& m) -> const UOp* {
    return m["x"]->dtype == DType::Bool ? g.iconst(DType::Bool, 1) : nullptr;
  }, "x|true");

  pm.add(P::op(Op::Sub, {X(), X()}), int_zero, "x-x");
  pm.add(P::op(Op::Xor, {X(), X()}), zero_of_x, "x^x");
  pm.add(P::op(Op::And, {X(), X()}), keep_x, "x&x");
  pm.add(P::op(Op::Or, {X(), X()}), keep_x, "x|x");
  pm.add(P::op(Op::Max, {X(), X()}), keep_x, "max(x,x)");
  pm.add(P::op(Op::CmpLt, {X(), X()}), [](Graph& g, const Match&) { return g.iconst(DType::Bool, 0); }, "x<x");
  pm.add(P::op(Op::CmpNe, {X(), X()}), [](Graph& g, const Match& m) -> const UOp* {  // NaN != NaN
    return is_float(m["x"]->dtype) ? nullptr : g.iconst(DType::Bool, 0);
  }, "x!=x");

  pm.add(P::op(Op::Neg, {P::op(Op::Neg, {X()})}), keep_x, "--x");
  pm.add(P::op(Op::Cast, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {
    return m["x"]->dtype == m["self"]->dtype ? m["x"] : nullptr;
  }, "cast same");

  pm.add(P::op(Op::Where, {P::cvar("c"), P::any("a"), P::any("b")}),
         [](Graph&, const Match& m) { return m["c"]->value.i ? m["a"] : m["b"]; }, "where const");
  pm.add(P::op(Op::Where, {P::any("c"), X(), X()}), keep_x, "where same");

  // Integer constants combine: (x+c1)+c2 -> x+(c1+c2), likewise for Mul. Not for floats (rounding).
  for (Op op : {Op::Add, Op::Mul})
    pm.add(P::op(op, {P::op(op, {P::any("x"), P::cvar("c1")}), P::cvar("c2")}),
           [op](Graph& g, const Match& m) -> const UOp* {
             const UOp* x = m["x"];
             if (is_float(x->dtype)) return nullptr;
             Scalar c = eval_op(op, x->dtype, {m["c1"]->value, m["c2"]->value});
             return g.alu(op, {x, g.constant(c)});
           }, "reassoc");
  return pm;
}

}  // namespace

const PatternMatcher& symbolic() {
  static const PatternMatcher pm = build();
  return pm;
}

}  // namespace nfcuop
