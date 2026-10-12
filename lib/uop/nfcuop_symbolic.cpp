// nfcuop stage 2: the symbolic simplifier. See nfcuop.hpp for what it promises.
#include "nfcuop.hpp"

namespace nfcuop {

namespace {

// A constant of the dtype and shape of `like`.
const UOp* zero(Graph& g, const UOp* like) { return g.constant(Scalar::from_int(like->dtype, 0), like->shape); }
const UOp* boolean(Graph& g, const UOp* like, bool v) { return g.constant(Scalar::from_int(DType::Bool, v), like->shape); }

PatternMatcher build() {
  PatternMatcher pm;
  using P = Pat;
  auto ordered = [](P p) { p.ordered(); return p; };
  auto X = [] { return P::any("x"); };

  // Constant folding: an ALU node or a Cast whose sources are all constants.
  pm.add(P::any("x"), [](Graph& g, const Match& m) -> const UOp* {
    const UOp* x = m["x"];
    if (x->src.empty() || !(is_alu(x->op) || x->op == Op::Cast)) return nullptr;  // all sources have x's shape
    std::vector<Scalar> args;
    for (const UOp* s : x->src) {
      if (!s->is_const()) return nullptr;
      args.push_back(s->value);
    }
    try {
      return g.constant(eval_op(x->op, x->dtype, args), x->shape);
    } catch (const Error&) {
      return nullptr;  // an integer division by zero stays in the graph and fails when it is evaluated
    }
  }, "fold");

  // Constants to the right of a commutative op.
  for (Op op : {Op::Add, Op::Mul, Op::Max, Op::CmpNe, Op::And, Op::Or, Op::Xor})
    pm.add(ordered(P::op(op, {P::cvar("c"), P::any("x")}, "self")),
           [](Graph& g, const Match& m) { return g.rebuild(m["self"], {m["x"], m["c"]}); }, "canon");

  auto keep_x = [](Graph&, const Match& m) { return m["x"]; };
  auto zero_of_x = [](Graph& g, const Match& m) { return zero(g, m["x"]); };
  auto int_zero = [](Graph& g, const Match& m) -> const UOp* {  // exact for ints and bool only: 0 * inf is NaN
    return is_float(m["x"]->dtype) ? nullptr : zero(g, m["x"]);
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
    return m["x"]->dtype == DType::Bool ? boolean(g, m["x"], true) : nullptr;
  }, "x|true");

  pm.add(P::op(Op::Sub, {X(), X()}), int_zero, "x-x");
  pm.add(P::op(Op::Xor, {X(), X()}), zero_of_x, "x^x");
  pm.add(P::op(Op::And, {X(), X()}), keep_x, "x&x");
  pm.add(P::op(Op::Or, {X(), X()}), keep_x, "x|x");
  pm.add(P::op(Op::Max, {X(), X()}), keep_x, "max(x,x)");
  pm.add(P::op(Op::CmpLt, {X(), X()}), [](Graph& g, const Match& m) { return boolean(g, m["x"], false); }, "x<x");
  pm.add(P::op(Op::CmpNe, {X(), X()}), [](Graph& g, const Match& m) -> const UOp* {  // NaN != NaN
    return is_float(m["x"]->dtype) ? nullptr : boolean(g, m["x"], false);
  }, "x!=x");

  pm.add(P::op(Op::Neg, {P::op(Op::Neg, {X()})}), keep_x, "--x");
  pm.add(P::op(Op::Cast, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {
    return m["x"]->dtype == m["self"]->dtype ? m["x"] : nullptr;
  }, "cast same");

  pm.add(P::op(Op::Where, {P::cvar("c"), P::any("a"), P::any("b")}),
         [](Graph&, const Match& m) { return m["c"]->value.i ? m["a"] : m["b"]; }, "where const");
  pm.add(P::op(Op::Where, {P::any("c"), X(), X()}), keep_x, "where same");

  // Movement ops and reductions (stage 3). A constant tensor stays a Const under any of them.
  for (Op op : {Op::Reshape, Op::Expand, Op::Permute, Op::Shrink, Op::Flip})
    pm.add(P::op(op, {P::cvar("c")}, "self"),
           [](Graph& g, const Match& m) { return g.constant(m["c"]->value, m["self"]->shape); }, "move const");
  pm.add(P::op(Op::ReduceMax, {P::cvar("c")}, "self"),
         [](Graph& g, const Match& m) { return g.constant(m["c"]->value, m["self"]->shape); }, "max const");
  pm.add(P::op(Op::ReduceSum, {P::cvar("c")}, "self"), [](Graph& g, const Match& m) -> const UOp* {
    const UOp* c = m["c"];
    if (is_float(c->dtype)) return nullptr;  // n additions round
    int64_t n = numel(c->shape) / numel(m["self"]->shape);
    return g.constant(eval_op(Op::Mul, c->dtype, {c->value, Scalar::from_int(c->dtype, n)}), m["self"]->shape);
  }, "sum const");
  for (Op op : {Op::Reshape, Op::Expand})  // to the shape the node already has
    pm.add(P::op(op, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {
      return m["x"]->shape == m["self"]->shape ? m["x"] : nullptr;
    }, "same shape");
  pm.add(P::op(Op::Reshape, {P::op(Op::Reshape, {X()})}, "self"),
         [](Graph& g, const Match& m) { return g.reshape(m["x"], m["self"]->shape); }, "reshape reshape");
  pm.add(P::op(Op::Expand, {P::op(Op::Expand, {X()})}, "self"),
         [](Graph& g, const Match& m) { return g.expand(m["x"], m["self"]->shape); }, "expand expand");
  pm.add(P::op(Op::Permute, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {  // the identity permutation
    const Shape& p = m["self"]->arg;
    for (size_t k = 0; k < p.size(); k++) if (p[k] != static_cast<int64_t>(k)) return nullptr;
    return m["x"];
  }, "permute id");
  pm.add(P::op(Op::Permute, {P::op(Op::Permute, {X()}, "inner")}, "self"), [](Graph& g, const Match& m) {
    const Shape& p1 = m["inner"]->arg;
    const Shape& p2 = m["self"]->arg;
    Shape c;
    for (int64_t i : p2) c.push_back(p1[i]);
    return g.permute(m["x"], c);
  }, "permute permute");
  pm.add(P::op(Op::Shrink, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {  // keeping everything
    return m["x"]->shape == m["self"]->shape ? m["x"] : nullptr;
  }, "shrink all");
  pm.add(P::op(Op::Pad, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {  // padding by nothing
    return m["x"]->shape == m["self"]->shape ? m["x"] : nullptr;
  }, "pad none");
  pm.add(P::op(Op::Flip, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {  // flipping no axis, or axes of size 1
    for (int64_t ax : m["self"]->arg) if (m["x"]->shape[ax] != 1) return nullptr;
    return m["x"];
  }, "flip trivial");
  pm.add(P::op(Op::Flip, {P::op(Op::Flip, {X()}, "inner")}, "self"), [](Graph&, const Match& m) -> const UOp* {
    return m["inner"]->arg == m["self"]->arg ? m["x"] : nullptr;  // the same flip twice
  }, "flip flip");
  for (Op op : {Op::ReduceSum, Op::ReduceMax})  // reducing axes of size 1 changes nothing
    pm.add(P::op(op, {X()}, "self"), [](Graph&, const Match& m) -> const UOp* {
      return m["x"]->shape == m["self"]->shape ? m["x"] : nullptr;
    }, "reduce size 1");

  // Integer constants combine: (x+c1)+c2 -> x+(c1+c2), likewise for Mul. Not for floats (rounding).
  for (Op op : {Op::Add, Op::Mul})
    pm.add(P::op(op, {P::op(op, {P::any("x"), P::cvar("c1")}), P::cvar("c2")}),
           [op](Graph& g, const Match& m) -> const UOp* {
             const UOp* x = m["x"];
             if (is_float(x->dtype)) return nullptr;
             Scalar c = eval_op(op, x->dtype, {m["c1"]->value, m["c2"]->value});
             return g.alu(op, {x, g.constant(c, x->shape)});
           }, "reassoc");
  return pm;
}

}  // namespace

const PatternMatcher& symbolic() {
  static const PatternMatcher pm = build();
  return pm;
}

}  // namespace nfcuop
