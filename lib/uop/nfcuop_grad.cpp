// nfcuop::hir::gradients: the vector-Jacobian products of the ONNX operators. See nfcuop_grad.hpp.
#include "nfcuop_grad.hpp"

#include <algorithm>
#include <climits>

namespace nfcuop {
namespace hir {

namespace {

// Appends nodes to the graph; constants are shared by content within one gradients() call.
struct Builder {
  Graph& g;
  std::map<std::string, int> consts;

  const Shape& shape(int v) const { return g.value(v).shape; }
  DType dtype(int v) const { return g.value(v).dtype; }

  int node(const std::string& op, std::vector<int> in, std::vector<Attribute> attrs = {}) { return g.add_node(op, std::move(in), std::move(attrs)); }
  int ints(const std::vector<int64_t>& v) {
    std::string key = "i" + to_string(v);
    auto it = consts.find(key);
    if (it != consts.end()) return it->second;
    Array a;
    a.dtype = DType::Int64;
    a.shape = {static_cast<int64_t>(v.size())};
    for (int64_t x : v) a.data.push_back(Scalar::from_int(DType::Int64, x));
    return consts[key] = g.add_initializer("", a);
  }
  int scalar(DType d, double v) {
    std::string key = std::string("s") + name(d) + std::to_string(v);
    auto it = consts.find(key);
    if (it != consts.end()) return it->second;
    return consts[key] = g.add_initializer("", Array(d, {}, {Scalar::from_double(d, v)}));
  }
  int zeros(DType d, const Shape& s) {
    int z = scalar(d, 0);
    return s.empty() ? z : node("Expand", {z, ints(s)});
  }
  int reshape(int v, const Shape& s) { return shape(v) == s ? v : node("Reshape", {v, ints(s)}); }
  int reduce_sum(int v, const std::vector<int64_t>& axes, bool keep) {
    return node("ReduceSum", {v, ints(axes)}, {Attribute::Int("keepdims", keep ? 1 : 0)});
  }
  int sum_all(int v) { return node("ReduceSum", {v}, {Attribute::Int("keepdims", 0)}); }
  // Undoes numpy broadcasting: sums `v` over the leading dimensions and over the size-1 dimensions of `s` that it was expanded along.
  int unbroadcast(int v, const Shape& s) {
    const Shape& vs = shape(v);
    if (vs == s) return v;
    const size_t lead = vs.size() - s.size();
    std::vector<int64_t> axes;
    for (size_t k = 0; k < vs.size(); k++)
      if (k < lead || (s[k - lead] == 1 && vs[k] != 1)) axes.push_back(static_cast<int64_t>(k));
    return reshape(axes.empty() ? v : reduce_sum(v, axes, true), s);
  }
  int swap_last(int v) {
    const int64_t r = static_cast<int64_t>(shape(v).size());
    std::vector<int64_t> perm;
    for (int64_t k = 0; k < r; k++) perm.push_back(k);
    std::swap(perm[r - 1], perm[r - 2]);
    return node("Transpose", {v}, {Attribute::Ints("perm", perm)});
  }
  int where(int c, int a, int d) { return node("Where", {c, a, d}); }
};

struct Reverse {
  Builder b;
  std::vector<char> dep;   // the value is a wrt or depends on one (never a bool value: masks are constants)
  std::map<int, int> adj;  // value -> its accumulated gradient

  explicit Reverse(Graph& g) : b{g, {}} {}

  // Adds `gv` (the value's shape, or a broadcast of it) to the gradient of value `v`.
  void accum(int v, int gv) {
    if (v < 0 || static_cast<size_t>(v) >= dep.size() || !dep[v]) return;
    DType d = b.dtype(v);
    if (!is_float(d))
      throw Error(std::string("gradients: a gradient would flow into the ") + name(d) + " value " + b.g.value(v).name +
                  ", which depends on a differentiated value through a cast to an integer type");
    gv = b.unbroadcast(gv, b.shape(v));
    auto it = adj.find(v);
    if (it == adj.end()) adj[v] = gv;
    else it->second = b.node("Add", {it->second, gv});
  }
  // whether the value takes a gradient (so that a rule can skip the work for constant operands)
  bool need(int v) const { return v >= 0 && static_cast<size_t>(v) < dep.size() && dep[v] && b.dtype(v) != DType::Bool; }

  std::vector<int64_t> reduce_axes(const Node& n) const {
    const Shape& s = b.shape(n.inputs[0]);
    std::vector<int64_t> axes;
    if (n.inputs.size() > 1 && n.inputs[1] >= 0)
      for (int64_t a : b.g.const_ints(n.inputs[1])) axes.push_back(a < 0 ? a + static_cast<int64_t>(s.size()) : a);
    if (axes.empty()) for (size_t k = 0; k < s.size(); k++) axes.push_back(static_cast<int64_t>(k));
    std::sort(axes.begin(), axes.end());
    return axes;
  }
  // the shape of a reduction's input with the reduced axes set to 1
  Shape keep_shape(const Node& n) const {
    Shape k = b.shape(n.inputs[0]);
    for (int64_t a : reduce_axes(n)) k[a] = 1;
    return k;
  }

  // Scatters the gradient `v` of a strided slice of one axis back to `dim` elements, zeros elsewhere: reverse for a negative
  // step, put step - 1 zeros after every element, then Pad.
  int unslice_axis(int v, int64_t axis, int64_t dim, SliceIdx ix) {
    DType d = b.dtype(v);
    int64_t start = ix.start, step = ix.count == 1 ? 1 : ix.step;
    if (step < 0) {  // after the reversal the run is ascending and starts at the lowest selected index
      v = b.node("Slice", {v, b.ints({-1}), b.ints({INT64_MIN}), b.ints({axis}), b.ints({-1})});
      start += (ix.count - 1) * step;
      step = -step;
    }
    int64_t len = ix.count;
    if (step > 1) {  // (.., count, 1, ..) ++ (.., count, step - 1, ..) of zeros along the new axis, merged, trailing zeros cut off
      Shape s1 = b.shape(v), merged = b.shape(v);
      s1.insert(s1.begin() + axis + 1, 1);
      Shape z = s1;
      z[axis + 1] = step - 1;
      int cat = b.node("Concat", {b.reshape(v, s1), b.zeros(d, z)}, {Attribute::Int("axis", axis + 1)});
      merged[axis] = ix.count * step;
      len = (ix.count - 1) * step + 1;
      v = b.reshape(cat, merged);
      if (len < merged[axis]) v = b.node("Slice", {v, b.ints({0}), b.ints({len}), b.ints({axis})});
    }
    if (len == dim) return v;
    std::vector<int64_t> pads(2 * b.shape(v).size(), 0);
    pads[axis] = start;
    pads[b.shape(v).size() + axis] = dim - start - len;
    return b.node("Pad", {v, b.ints(pads)});
  }

  // The contribution of node `n` (whose output has the gradient `gy`) to the gradients of its inputs.
  void step(const Node& n, int gy) {
    const std::string& op = n.op;
    const std::vector<int>& in = n.inputs;
    const int y = n.output;
    auto X = [&](size_t k) { return in.at(k); };
    const DType dt = b.dtype(y);
    auto sc = [&](double v) { return b.scalar(dt, v); };
    auto mul = [&](int p, int q) { return b.node("Mul", {p, q}); };
    auto neg = [&](int p) { return b.node("Neg", {p}); };

    if (op == "Identity") accum(X(0), gy);
    else if (op == "Cast") {
      DType from = b.dtype(X(0));
      if (!is_float(from)) accum(X(0), gy);  // a bool input is dropped, an integer one throws
      else accum(X(0), from == dt ? gy : b.node("Cast", {gy}, {Attribute::Int("to", onnx_dtype(from))}));
    }
    else if (op == "Neg") accum(X(0), neg(gy));
    else if (op == "Abs") {
      int x = X(0), zero = sc(0);
      accum(x, b.where(b.node("Greater", {x, zero}), gy, b.where(b.node("Less", {x, zero}), neg(gy), zero)));  // 0 at 0
    }
    else if (op == "Relu") accum(X(0), b.where(b.node("Greater", {X(0), sc(0)}), gy, sc(0)));  // 0 at 0
    else if (op == "Sqrt") accum(X(0), b.node("Div", {gy, mul(y, sc(2))}));
    else if (op == "Exp") accum(X(0), mul(gy, y));
    else if (op == "Log") accum(X(0), b.node("Div", {gy, X(0)}));
    else if (op == "Sin") accum(X(0), mul(gy, b.node("Cos", {X(0)})));
    else if (op == "Cos") accum(X(0), neg(mul(gy, b.node("Sin", {X(0)}))));
    else if (op == "Tanh") accum(X(0), mul(gy, b.node("Sub", {sc(1), mul(y, y)})));
    else if (op == "Sigmoid") accum(X(0), mul(gy, mul(y, b.node("Sub", {sc(1), y}))));
    else if (op == "Add") { accum(X(0), gy); accum(X(1), gy); }
    else if (op == "Sub") { accum(X(0), gy); if (need(X(1))) accum(X(1), neg(gy)); }
    else if (op == "Mul") {
      if (need(X(0))) accum(X(0), mul(gy, X(1)));
      if (need(X(1))) accum(X(1), mul(gy, X(0)));
    }
    else if (op == "Div") {
      if (need(X(0))) accum(X(0), b.node("Div", {gy, X(1)}));
      if (need(X(1))) accum(X(1), neg(b.node("Div", {mul(gy, y), X(1)})));  // -g * a / b^2 = -(g * y) / b
    }
    else if (op == "Max" || op == "Min") {
      // the winner takes the gradient; at a tie each operand gets half
      int a = X(0), c = X(1);
      int wa = b.where(b.node(op == "Max" ? "Greater" : "Less", {a, c}), sc(1), b.where(b.node("Equal", {a, c}), sc(0.5), sc(0)));
      if (need(a)) accum(a, mul(gy, wa));
      if (need(c)) accum(c, mul(gy, b.node("Sub", {sc(1), wa})));
    }
    else if (op == "Where") {
      int c = X(0), zero = sc(0);
      if (need(X(1))) accum(X(1), b.where(c, gy, zero));
      if (need(X(2))) accum(X(2), b.where(c, zero, gy));
    }
    else if (op == "Clip") {
      // x gets the gradient where lo <= x <= hi (closed); lo and hi get what is cut off outside
      int x = X(0), lo = in.size() > 1 ? in[1] : -1, hi = in.size() > 2 ? in[2] : -1, zero = sc(0);
      int inside = -1;
      if (lo >= 0) inside = b.node("GreaterOrEqual", {x, lo});
      if (hi >= 0) {
        int le = b.node("LessOrEqual", {x, hi});
        inside = inside < 0 ? le : b.node("And", {inside, le});
      }
      accum(x, inside < 0 ? gy : b.where(inside, gy, zero));
      if (need(lo)) accum(lo, b.sum_all(b.where(b.node("Less", {x, lo}), gy, zero)));
      if (need(hi)) accum(hi, b.sum_all(b.where(b.node("Greater", {x, hi}), gy, zero)));
    }
    else if (op == "MatMul") {
      // 1-D operands are viewed as (1, K) and (K, 1); then dA = G B^T and dB = A^T G with the batch dimensions summed back
      int a = X(0), c = X(1);
      const Shape &sa = b.shape(a), &sb = b.shape(c), &sg = b.shape(gy);
      const bool a1 = sa.size() == 1, b1 = sb.size() == 1;
      const int64_t M = a1 ? 1 : sa[sa.size() - 2], K = sa.back(), N = b1 ? 1 : sb.back();
      Shape g2(sg.begin(), sg.end() - (a1 ? 0 : 1) - (b1 ? 0 : 1));
      g2.push_back(M);
      g2.push_back(N);
      Shape a2 = a1 ? Shape{1, K} : sa, b2 = b1 ? Shape{K, 1} : sb;
      int G2 = b.reshape(gy, g2);
      if (need(a)) accum(a, b.reshape(b.unbroadcast(b.node("MatMul", {G2, b.swap_last(b.reshape(c, b2))}), a2), sa));
      if (need(c)) accum(c, b.reshape(b.unbroadcast(b.node("MatMul", {b.swap_last(b.reshape(a, a2)), G2}), b2), sb));
    }
    else if (op == "Transpose") {
      std::vector<int64_t> perm, inv(b.shape(X(0)).size());
      if (const Attribute* p = n.attr("perm")) perm = p->ints;
      else for (size_t k = inv.size(); k-- > 0;) perm.push_back(static_cast<int64_t>(k));
      for (size_t k = 0; k < perm.size(); k++) inv[perm[k]] = static_cast<int64_t>(k);
      accum(X(0), b.node("Transpose", {gy}, {Attribute::Ints("perm", inv)}));
    }
    else if (op == "Reshape" || op == "Squeeze" || op == "Unsqueeze") accum(X(0), b.reshape(gy, b.shape(X(0))));
    else if (op == "Expand") accum(X(0), gy);  // accum sums it back to the operand's shape
    else if (op == "ReduceSum" || op == "ReduceMean") {
      int k = b.reshape(gy, keep_shape(n));
      if (op == "ReduceMean") k = b.node("Div", {k, sc(static_cast<double>(numel(b.shape(X(0))) / numel(b.shape(y))))});
      accum(X(0), b.node("Expand", {k, b.ints(b.shape(X(0)))}));
    }
    else if (op == "ReduceMax" || op == "ReduceMin") {
      // every element equal to the extreme shares the gradient evenly
      int x = X(0), gk = b.reshape(gy, keep_shape(n)), yk = b.reshape(y, keep_shape(n));
      int mask = b.node("Cast", {b.node("Equal", {x, yk})}, {Attribute::Int("to", onnx_dtype(dt))});
      accum(x, mul(b.node("Div", {mask, b.reduce_sum(mask, reduce_axes(n), true)}), gk));
    }
    else if (op == "Softmax" || op == "LogSoftmax") {
      int64_t axis = n.attr_int("axis", -1);
      if (axis < 0) axis += static_cast<int64_t>(b.shape(y).size());
      if (op == "Softmax") accum(X(0), mul(y, b.node("Sub", {gy, b.reduce_sum(mul(y, gy), {axis}, true)})));
      else accum(X(0), b.node("Sub", {gy, mul(b.node("Exp", {y}), b.reduce_sum(gy, {axis}, true))}));
    }
    else if (op == "Slice") {
      const Shape& s = b.shape(X(0));
      std::vector<int64_t> starts = b.g.const_ints(in[1]), ends = b.g.const_ints(in[2]), axes, steps;
      if (in.size() > 3 && in[3] >= 0) axes = b.g.const_ints(in[3]); else for (size_t k = 0; k < starts.size(); k++) axes.push_back(static_cast<int64_t>(k));
      if (in.size() > 4 && in[4] >= 0) steps = b.g.const_ints(in[4]); else steps.assign(starts.size(), 1);
      int v = gy;
      for (size_t k = 0; k < starts.size(); k++) {  // the axes are independent
        int64_t ax = axes[k] < 0 ? axes[k] + static_cast<int64_t>(s.size()) : axes[k];
        v = unslice_axis(v, ax, s[ax], slice_indices(s[ax], true, starts[k], true, ends[k], steps[k]));
      }
      accum(X(0), v);
    }
    else if (op == "Concat") {
      int64_t axis = n.attr_int("axis", 0), at = 0;
      if (axis < 0) axis += static_cast<int64_t>(b.shape(y).size());
      for (int xi : in) {
        const int64_t len = b.shape(xi).at(axis);
        if (need(xi)) accum(xi, in.size() == 1 ? gy : b.node("Slice", {gy, b.ints({at}), b.ints({at + len}), b.ints({axis})}));
        at += len;
      }
    }
    else if (op == "Pad") {
      const size_t r = b.shape(X(0)).size();
      std::vector<int64_t> pads = b.g.const_ints(in[1]), starts(pads.begin(), pads.begin() + static_cast<std::ptrdiff_t>(r)), ends, axes;
      for (size_t k = 0; k < r; k++) {
        ends.push_back(starts[k] + b.shape(X(0))[k]);
        axes.push_back(static_cast<int64_t>(k));
      }
      int inner = r == 0 ? gy : b.node("Slice", {gy, b.ints(starts), b.ints(ends), b.ints(axes)});
      accum(X(0), inner);
      if (in.size() > 2 && need(in[2])) accum(in[2], b.node("Sub", {b.sum_all(gy), b.sum_all(inner)}));  // what the padding holds
    }
    else throw Error(op + ": no gradient rule (the value " + b.g.value(y).name + " depends on a differentiated value)");
  }
};

}  // namespace

std::vector<int> gradients(Graph& g, int loss, const std::vector<int>& wrt) {
  const Value lv = g.value(loss);
  if (!lv.shape.empty()) throw Error("gradients: the loss must be a scalar, got shape " + to_string(lv.shape));
  if (!is_float(lv.dtype)) throw Error(std::string("gradients: the loss must be a float value, got ") + name(lv.dtype));
  for (int w : wrt)
    if (!is_float(g.value(w).dtype)) throw Error("gradients: " + g.value(w).name + " is " + name(g.value(w).dtype) + "; only float values can be differentiated");

  Reverse r(g);
  const size_t nn = g.nodes().size();
  r.dep.assign(g.num_values(), 0);
  for (int w : wrt) r.dep[w] = 1;
  for (size_t k = 0; k < nn; k++) {
    const Node& n = g.nodes()[k];
    if (g.value(n.output).dtype == DType::Bool) continue;  // comparisons and logic: masks are constants
    for (int in : n.inputs) if (in >= 0 && r.dep[in]) r.dep[n.output] = 1;
  }
  if (r.dep[loss]) r.adj[loss] = r.b.scalar(lv.dtype, 1);
  for (size_t k = nn; k-- > 0;) {  // nodes are in topological order: every use of a value is seen before its producer
    Node n = g.nodes()[k];         // a copy: step() appends nodes
    auto it = r.adj.find(n.output);
    if (!r.dep[n.output] || it == r.adj.end()) continue;
    r.step(n, it->second);
  }
  std::vector<int> out;
  for (int w : wrt) {
    auto it = r.adj.find(w);
    int d = it != r.adj.end() ? it->second : r.b.zeros(g.value(w).dtype, g.value(w).shape);
    if (g.value(d).shape != g.value(w).shape || g.value(d).dtype != g.value(w).dtype)
      throw Error("gradients: internal error, the gradient of " + g.value(w).name + " has the wrong shape");
    out.push_back(d);
  }
  return out;
}

}  // namespace hir
}  // namespace nfcuop
