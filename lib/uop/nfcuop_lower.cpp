// nfcuop::hir::Lowerer: the ONNX operators of a hir::Graph as UOp tensors (nfcuop_ut.hpp). See nfcuop_hir.hpp.
#include "nfcuop_hir.hpp"

#include <algorithm>
#include <cstddef>
#include <limits>
#include <memory>
#include <set>
#include <vector>

namespace nfcuop {
namespace hir {

namespace {

// Operator notes. There is no gather, sliding-window or erf primitive in the UOp layer, so these are built from the movement
// and ALU ops that exist (cost in brackets; n = the number of output elements):
//   Gather     one-hot select: where(idx == j, data, -0.0) summed over the axis [n * S elements, S = the axis size]
//   Erf        Taylor series in float64 (no cancellation), see erf_tensor [about 4 * 64 nodes per Erf, float64 work]
//   Conv       one strided slice of the padded input per kernel position, one matmul per position [K matmuls, K = kernel size]
//   MaxPool    the same slices and K-1 Max nodes (a NaN in a window is ignored, as ut::maximum ignores a NaN operand: not checked
//              against onnxruntime); AveragePool the slices, a sum and a divide by a constant of the output shape
//   norms      mean and population variance (ut::Tensor::var), then the formula

constexpr int kErfTerms = 100;  // see erf_tensor

// Calls f for every index of `shape` in row-major order (a kernel, or the positions of an output).
template <class F>
void for_each_index(const Shape& shape, F f) {
  Shape at(shape.size(), 0);
  for (;;) {
    f(at);
    size_t k = shape.size();
    while (k > 0 && ++at[k - 1] == shape[k - 1]) at[--k] = 0;
    if (k == 0) return;
  }
}

Shape attr_axes(const Node& n, const char* name, size_t count, int64_t dflt) {
  Shape v = n.attr_ints(name);
  return v.empty() ? Shape(count, dflt) : v;
}

// Zero (or -inf, for MaxPool) padding of the spatial axes of an (N, C, D1, ...) tensor.
ut::Tensor pad_spatial(const ut::Tensor& x, const Shape& pb, const Shape& pe, bool neg_inf) {
  const size_t d = pb.size();
  if (std::all_of(pb.begin(), pb.end(), [](int64_t v) { return v == 0; }) && std::all_of(pe.begin(), pe.end(), [](int64_t v) { return v == 0; })) return x;
  Shape before(x.ndim(), 0), after(x.ndim(), 0);
  for (size_t k = 0; k < d; k++) { before[2 + k] = pb[k]; after[2 + k] = pe[k]; }
  if (neg_inf) return x.pad(before, after, Scalar::from_double(x.dtype(), -std::numeric_limits<double>::infinity()));
  return x.pad(before, after);
}

// The input elements that the outputs read at kernel position `kappa`: a strided slice per spatial axis of the padded input.
ut::Tensor window_slice(const ut::Tensor& xp, const Shape& kappa, const Shape& out, const Shape& strides, const Shape& dil) {
  ut::Tensor t = xp;
  for (size_t k = 0; k < out.size(); k++) {
    const int64_t start = kappa[k] * dil[k];
    t = t.slice(static_cast<int64_t>(2 + k), true, start, true, start + (out[k] - 1) * strides[k] + 1, strides[k]);
  }
  return t;
}

// AveragePool's divisors per output position: the kernel's size (count_include_pad=1) or the number of input elements under the
// window. Both are separable per spatial axis: the count of kernel positions whose input index lies inside the input.
Array average_divisors(const Shape& in, const Shape& out, const Shape& kernel, const Shape& strides, const Shape& dil, const Shape& pb, bool include_pad, DType dt) {
  const size_t d = out.size();
  std::vector<Shape> cnt(d);
  for (size_t k = 0; k < d; k++)
    for (int64_t o = 0; o < out[k]; o++) {
      int64_t c = 0;
      for (int64_t kk = 0; kk < kernel[k]; kk++) {
        const int64_t idx = o * strides[k] + kk * dil[k] - pb[k];
        if (include_pad || (idx >= 0 && idx < in[k])) c++;
      }
      cnt[k].push_back(c);
    }
  Array a(dt, out, {});
  for_each_index(out, [&](const Shape& at) {
    double v = 1;
    for (size_t k = 0; k < d; k++) v *= static_cast<double>(cnt[k][static_cast<size_t>(at[k])]);
    a.data.push_back(Scalar::from_double(dt, v));
  });
  return a;
}

// Gather along `axis` (non-negative) with int indices of any shape: out[.., i, ..] = data[.., idx[i], ..] (negative indices count from
// the end). Each output row picks its element with a one-hot mask: sum_j where(idx == j, data[.., j, ..], fill). The fill is -0.0 in
// float, so that the sum (which starts from the first element) gives exactly the selected value, -0.0 included. An index out of range
// selects nothing and gives -0.0 (or 0); constant indices are checked by shape inference, runtime indices are not.
ut::Tensor gather(ut::Session& s, const ut::Tensor& data, const ut::Tensor& idx, int64_t axis) {
  const Shape D = data.shape(), I = idx.shape();
  const int64_t S = D[static_cast<size_t>(axis)];
  const size_t P = static_cast<size_t>(axis), q = I.size(), Q = D.size() - P - 1;
  ut::Tensor ix = idx.astype(DType::Int64);
  ix = ut::where(ix < 0, ix + S, ix);
  Shape ishape(P, 1);
  ishape.insert(ishape.end(), I.begin(), I.end());
  ishape.push_back(1);
  ishape.insert(ishape.end(), Q, 1);
  Shape eshape(D.begin(), D.begin() + static_cast<std::ptrdiff_t>(P));
  eshape.insert(eshape.end(), I.begin(), I.end());
  eshape.push_back(S);
  eshape.insert(eshape.end(), D.begin() + static_cast<std::ptrdiff_t>(P) + 1, D.end());
  Shape rshape(D.begin(), D.begin() + static_cast<std::ptrdiff_t>(P));
  rshape.insert(rshape.end(), q, 1);
  rshape.insert(rshape.end(), D.begin() + static_cast<std::ptrdiff_t>(P), D.end());
  Shape arshape(P, 1);
  arshape.insert(arshape.end(), q, 1);
  arshape.push_back(S);
  arshape.insert(arshape.end(), Q, 1);
  ut::Tensor hit = ix.reshape(ishape) == s.arange(S, DType::Int64).reshape(arshape);
  const bool fl = is_float(data.dtype());
  ut::Tensor fill(&s, s.graph().constant(Scalar::from_double(data.dtype(), fl ? -0.0 : 0.0)));
  ut::Tensor sel = ut::where(hit, data.reshape(rshape), fill);
  return sel.sum(static_cast<int64_t>(P + q));
}

// erf(x) = 2/sqrt(pi) exp(-x^2) sum_{n>=0} x (2x^2)^n / (1*3*...*(2n+1)): every term is positive, so there is no cancellation. It is
// evaluated in float64 on x clamped to [-6, 6]: erf(6) = 1 - 2e-17 is 1 in float64 (and in float32), so the clamp is exact beyond it, and
// it keeps the terms from overflowing. NaN is restored at the end. Measured against std::erf on [-6, 6]: 2.3e-15 relative (|erf| >= 1e-3)
// with kErfTerms = 100 (tests/uop/test_nn.cpp checks it). The result is rounded to the input dtype once.
ut::Tensor erf_tensor(const ut::Tensor& x) {
  const DType dt = x.dtype();
  ut::Tensor xd = dt == DType::Float64 ? x : x.astype(DType::Float64);
  ut::Tensor c = xd.clip(-6.0, 6.0);
  ut::Tensor x2 = c * c * 2.0;
  ut::Tensor term = c, sum = c;
  for (int k = 0; k < kErfTerms; k++) {
    term = term * x2 * (1.0 / (2 * k + 3));   // t_{k+1} = t_k * 2x^2 / (2k+3)
    sum = sum + term;
  }
  ut::Tensor y = sum * (-(c * c)).exp() * 1.1283791670955126;   // 2/sqrt(pi)
  y = ut::where(xd != xd, xd, y);
  return dt == DType::Float64 ? y : y.astype(dt);
}

}  // namespace

ut::Tensor Lowerer::get(int id) {
  auto it = memo_.find(id);
  if (it != memo_.end()) return it->second;
  // the values `id` needs that are not lowered yet: an explicit stack, then lowering in id order (producers have smaller ids)
  std::vector<int> need, stack{id};
  std::set<int> seen;
  while (!stack.empty()) {
    int v = stack.back();
    stack.pop_back();
    if (memo_.count(v) || !seen.insert(v).second) continue;
    need.push_back(v);
    if (g_.initializer(v) != nullptr || g_.producer(v) < 0) continue;
    for (int in : g_.nodes()[static_cast<size_t>(g_.producer(v))].inputs)
      if (in >= 0 && g_.initializer(in) == nullptr) stack.push_back(in);
  }
  std::sort(need.begin(), need.end());
  for (int v : need) lower_one(v);
  return memo_.at(id);
}

ut::Tensor Lowerer::lower_one(int id) {
  const Value& v = g_.value(id);
  if (!v.syms.empty()) {
    std::string syms;
    for (const std::string& x : v.syms) if (!x.empty()) syms += (syms.empty() ? "" : ", ") + x;
    throw Error("hir: lowering " + v.name + " needs its symbolic dimensions bound (" + syms + "): bind the graph first (Graph::bind, or hir::Evaluator)");
  }
  ut::Tensor out;
  if (const Array* a = g_.initializer(id)) {
    bool uniform = !a->data.empty();
    for (const Scalar& s : a->data) uniform = uniform && s == a->data[0];
    // a constant tensor with all elements equal is a Const (it folds); anything else is a buffer
    out = uniform ? ut::Tensor(&s_, s_.graph().constant(a->data[0], a->shape)) : s_.from(*a);
  } else if (g_.producer(id) < 0) {
    out = s_.placeholder(v.name, v.shape, v.dtype);
  } else {
    const Node& n = g_.nodes()[static_cast<size_t>(g_.producer(id))];
    const std::string& op = n.op;
    std::vector<ut::Tensor> in(n.inputs.size());
    for (size_t k = 0; k < n.inputs.size(); k++)
      if (n.inputs[k] >= 0 && g_.initializer(n.inputs[k]) == nullptr) in[k] = memo_.at(n.inputs[k]);
    // inputs that ONNX wants as constants are read, not lowered
    auto ints = [&](size_t k) { return g_.const_ints(n.inputs[k]); };
    auto has = [&](size_t k) { return k < n.inputs.size() && n.inputs[k] >= 0; };
    auto arg = [&](size_t k) { return in[k].valid() ? in[k] : get(n.inputs[k]); };   // an initializer used as data: lowered here
    if (op == "Identity") out = arg(0);
    else if (op == "Cast") out = arg(0).astype(v.dtype);
    else if (op == "Neg") out = -arg(0);
    else if (op == "Abs") out = arg(0).abs();
    else if (op == "Relu") out = arg(0).relu();
    else if (op == "Not") out = ut::logical_not(arg(0));
    else if (op == "Sqrt") out = arg(0).sqrt();
    else if (op == "Exp") out = arg(0).exp();
    else if (op == "Log") out = arg(0).log();
    else if (op == "Sin") out = arg(0).sin();
    else if (op == "Acos") out = arg(0).acos();
    else if (op == "Acosh") out = arg(0).acosh();
    else if (op == "Asin") out = arg(0).asin();
    else if (op == "Asinh") out = arg(0).asinh();
    else if (op == "Atan") out = arg(0).atan();
    else if (op == "Atanh") out = arg(0).atanh();
    else if (op == "Cosh") out = arg(0).cosh();
    else if (op == "Sinh") out = arg(0).sinh();
    else if (op == "Tan") out = arg(0).tan();
    else if (op == "Round") out = arg(0).round();
    else if (op == "Log2") out = arg(0).log2();
    else if (op == "Log10") out = arg(0).log10();
    else if (op == "Expm1") out = arg(0).expm1();
    else if (op == "Log1p") out = arg(0).log1p();
    else if (op == "Cos") out = arg(0).cos();
    else if (op == "Tanh") out = arg(0).tanh();
    else if (op == "Sigmoid") out = arg(0).sigmoid();
    else if (op == "Add") out = arg(0) + arg(1);
    else if (op == "Sub") out = arg(0) - arg(1);
    else if (op == "Mul") out = arg(0) * arg(1);
    else if (op == "Div") out = is_float(v.dtype) ? arg(0) / arg(1) : ut::trunc_divide(arg(0), arg(1));
    else if (op == "Mod") out = n.attr_int("fmod", 0) ? ut::c_remainder(arg(0), arg(1)) : ut::remainder(arg(0), arg(1));
    else if (op == "Max") out = ut::maximum(arg(0), arg(1));
    else if (op == "Min") out = ut::minimum(arg(0), arg(1));
    else if (op == "Atan2") out = ut::atan2(arg(0), arg(1));
    else if (op == "BitwiseLeftShift") out = ut::shift_left(arg(0), arg(1));
    else if (op == "BitwiseRightShift") out = ut::shift_right(arg(0), arg(1));
    else if (op == "And" || op == "BitwiseAnd") out = arg(0) & arg(1);
    else if (op == "Or" || op == "BitwiseOr") out = arg(0) | arg(1);
    else if (op == "Xor" || op == "BitwiseXor") out = arg(0) ^ arg(1);
    else if (op == "Equal") out = arg(0) == arg(1);
    else if (op == "Less") out = arg(0) < arg(1);
    else if (op == "Greater") out = arg(0) > arg(1);
    else if (op == "LessOrEqual") out = arg(0) <= arg(1);
    else if (op == "GreaterOrEqual") out = arg(0) >= arg(1);
    else if (op == "Where") out = ut::where(arg(0), arg(1), arg(2));
    else if (op == "Clip") {
      out = arg(0);
      if (has(1)) out = ut::maximum(out, arg(1));
      if (has(2)) out = ut::minimum(out, arg(2));
    }
    else if (op == "MatMul") out = ut::matmul(arg(0), arg(1));
    else if (op == "Transpose") out = n.has_attr("perm") ? arg(0).transpose(n.attr("perm")->ints) : arg(0).transpose();
    else if (op == "Reshape" || op == "Squeeze" || op == "Unsqueeze") out = arg(0).reshape(v.shape);
    else if (op == "Expand") out = arg(0).broadcast_to(v.shape);
    else if (op == "ReduceSum" || op == "ReduceMean" || op == "ReduceMax" || op == "ReduceMin" || op == "ReduceProd") {
      ut::Axes axes = has(1) ? ints(1) : ut::Axes{};   // none: all of them
      bool keep = n.attr_int("keepdims", 1) != 0;
      ut::Tensor x = arg(0);
      out = op == "ReduceSum" ? x.sum(axes, keep) : op == "ReduceMean" ? x.mean(axes, keep) : op == "ReduceMax" ? x.max(axes, keep)
            : op == "ReduceMin" ? x.min(axes, keep) : x.prod(axes, keep);
    }
    else if (op == "Softmax") out = arg(0).softmax(n.attr_int("axis", -1));
    else if (op == "LogSoftmax") out = arg(0).log_softmax(n.attr_int("axis", -1));
    else if (op == "Slice") {
      std::vector<int64_t> starts = ints(1), ends = ints(2), axes, steps;
      if (has(3)) axes = ints(3); else for (size_t k = 0; k < starts.size(); k++) axes.push_back(static_cast<int64_t>(k));
      if (has(4)) steps = ints(4); else steps.assign(starts.size(), 1);
      out = arg(0);
      for (size_t k = 0; k < starts.size(); k++) out = out.slice(axes[k], true, starts[k], true, ends[k], steps[k]);
    }
    else if (op == "Pad") {
      std::vector<int64_t> pads = ints(1);
      const size_t r = pads.size() / 2;
      Shape before(pads.begin(), pads.begin() + static_cast<std::ptrdiff_t>(r)), after(pads.begin() + static_cast<std::ptrdiff_t>(r), pads.end());
      out = has(2) ? arg(0).pad(before, after, g_.initializer(n.inputs[2])->data[0]) : arg(0).pad(before, after);
    }
    else if (op == "Concat") {
      std::vector<ut::Tensor> parts;
      for (size_t k = 0; k < n.inputs.size(); k++) parts.push_back(arg(k));
      out = ut::concatenate(parts, n.attr_int("axis", 0));
    }
    else if (op == "Erf") out = erf_tensor(arg(0));
    else if (op == "ArgMax" || op == "ArgMin")
      out = (op == "ArgMax" ? ut::argmax : ut::argmin)(arg(0), n.attr_int("axis", 0), n.attr_int("keepdims", 1) != 0, n.attr_int("select_last_index", 0) != 0);
    else if (op == "Tile") {   // (d0, d1, ..) -> (1, d0, 1, d1, ..) -> (r0, d0, r1, d1, ..) by Expand -> (r0 d0, r1 d1, ..)
      ut::Tensor x = arg(0);
      const std::vector<int64_t> reps = ints(1);
      Shape inter, big;
      for (size_t k = 0; k < x.shape().size(); k++) {
        inter.insert(inter.end(), {1, x.shape()[k]});
        big.insert(big.end(), {reps[k], x.shape()[k]});
      }
      out = x.reshape(inter).broadcast_to(big).reshape(v.shape);
    }
    else if (op == "CumSum") out = arg(0).cumsum(ints(1).at(0), n.attr_int("exclusive", 0) != 0, n.attr_int("reverse", 0) != 0);
    else if (op == "Pow") out = ut::pow(arg(0), arg(1));
    else if (op == "Floor") out = arg(0).floor();
    else if (op == "Ceil") out = arg(0).ceil();
    else if (op == "IsNaN") out = arg(0).isnan();
    else if (op == "IsInf") {   // +inf and/or -inf, by the attributes (both by default); neither: all false
      const ut::Tensor x = arg(0);
      const bool pos = n.attr_int("detect_positive", 1) != 0, neg = n.attr_int("detect_negative", 1) != 0;
      ut::Tensor hit;
      if (pos) hit = x == std::numeric_limits<double>::infinity();
      if (neg) hit = hit.valid() ? hit | (x == -std::numeric_limits<double>::infinity()) : x == -std::numeric_limits<double>::infinity();
      out = hit.valid() ? hit : s_.full(v.shape, 0, DType::Bool);
    }
    else if (op == "Gather") {
      int64_t ax = n.attr_int("axis", 0);
      ut::Tensor data = arg(0);
      if (ax < 0) ax += data.ndim();
      out = gather(s_, data, arg(1), ax);
    }
    else if (op == "Gemm") {
      ut::Tensor a = arg(0), b = arg(1);
      if (n.attr_int("transA", 0)) a = a.transpose();
      if (n.attr_int("transB", 0)) b = b.transpose();
      ut::Tensor y = ut::matmul(a, b);
      const double alpha = n.attr_float("alpha", 1.0), beta = n.attr_float("beta", 1.0);
      if (alpha != 1.0) y = y * alpha;
      if (has(2) && beta != 0.0) {   // beta = 0 ignores C (so a NaN in C does not reach the output)
        ut::Tensor c = arg(2);
        if (beta != 1.0) c = c * beta;
        y = y + c.broadcast_to(v.shape);
      }
      out = y;
    }
    else if (op == "Conv") {
      ut::Tensor x = arg(0), w = arg(1);
      const size_t d = static_cast<size_t>(x.ndim()) - 2;
      const int64_t N = x.shape()[0], C = x.shape()[1], M = w.shape()[0], G = n.attr_int("group", 1);
      Shape kernel(w.shape().begin() + 2, w.shape().end());
      Shape strides = attr_axes(n, "strides", d, 1), dil = attr_axes(n, "dilations", d, 1), pads = attr_axes(n, "pads", 2 * d, 0);
      Shape pb(pads.begin(), pads.begin() + static_cast<std::ptrdiff_t>(d)), pe(pads.begin() + static_cast<std::ptrdiff_t>(d), pads.end());
      const Shape O(v.shape.begin() + 2, v.shape.end());
      const int64_t L = numel(O);
      ut::Tensor xp = pad_spatial(x, pb, pe, false);
      ut::Tensor acc;
      for_each_index(kernel, [&](const Shape& kap) {
        ut::Tensor p = window_slice(xp, kap, O, strides, dil).reshape({N, G, C / G, L});
        ut::Tensor wk = w;
        for (size_t k = 0; k < d; k++) wk = wk.slice(static_cast<int64_t>(2 + k), true, kap[k], true, kap[k] + 1, 1);
        ut::Tensor term = ut::matmul(wk.reshape({G, M / G, C / G}), p);   // (N, G, M/G, L)
        acc = acc.valid() ? acc + term : term;
      });
      ut::Tensor y = acc.reshape(v.shape);
      if (has(2)) {
        Shape bs(v.shape.size(), 1);
        bs[1] = M;
        y = y + arg(2).reshape(bs);
      }
      out = y;
    }
    else if (op == "MaxPool" || op == "AveragePool") {
      ut::Tensor x = arg(0);
      const bool is_max = op == "MaxPool";
      const size_t d = static_cast<size_t>(x.ndim()) - 2;
      Shape kernel = attr_axes(n, "kernel_shape", d, 1), strides = attr_axes(n, "strides", d, 1), dil = attr_axes(n, "dilations", d, 1);
      Shape pads = attr_axes(n, "pads", 2 * d, 0);
      Shape pb(pads.begin(), pads.begin() + static_cast<std::ptrdiff_t>(d)), pe(pads.begin() + static_cast<std::ptrdiff_t>(d), pads.end());
      const Shape O(v.shape.begin() + 2, v.shape.end());
      ut::Tensor xp = pad_spatial(x, pb, pe, is_max);
      ut::Tensor acc;
      for_each_index(kernel, [&](const Shape& kap) {
        ut::Tensor t = window_slice(xp, kap, O, strides, dil);
        acc = !acc.valid() ? t : is_max ? ut::maximum(acc, t) : acc + t;
      });
      if (!is_max) {
        Shape in(x.shape().begin() + 2, x.shape().end());
        Array div = average_divisors(in, O, kernel, strides, dil, pb, n.attr_int("count_include_pad", 0) != 0, x.dtype());
        Shape ds(v.shape.size(), 1);
        std::copy(O.begin(), O.end(), ds.begin() + 2);
        acc = acc / s_.from(div).reshape(ds);
      }
      out = acc;
    }
    else if (op == "BatchNormalization") {   // inference: (x - mean) * scale / sqrt(var + eps) + B, per channel
      ut::Tensor x = arg(0);
      Shape ps(x.shape().size(), 1);
      ps[1] = x.shape()[1];
      auto P = [&](size_t k) { return arg(k).reshape(ps); };
      out = (x - P(3)) * P(1) / ut::sqrt(P(4) + n.attr_float("epsilon", 1e-5)) + P(2);
    }
    else if (op == "InstanceNormalization") {   // per (n, c), over the spatial axes
      ut::Tensor x = arg(0);
      ut::Axes sp;
      for (int64_t k = 2; k < x.ndim(); k++) sp.push_back(k);
      Shape ps(x.shape().size(), 1);
      ps[1] = x.shape()[1];
      ut::Tensor mu = x.mean(sp, true), var = x.var(sp, true);
      out = (x - mu) * arg(1).reshape(ps) / ut::sqrt(var + n.attr_float("epsilon", 1e-5)) + arg(2).reshape(ps);
    }
    else if (op == "LayerNormalization") {   // over the axes from `axis` on: (x - mean) / sqrt(var + eps) * Scale + B
      ut::Tensor x = arg(0);
      const int64_t r = x.ndim();
      int64_t axis = n.attr_int("axis", -1);
      if (axis < 0) axis += r;
      ut::Axes ax;
      Shape ps(static_cast<size_t>(r), 1);
      for (int64_t k = axis; k < r; k++) { ax.push_back(k); ps[static_cast<size_t>(k)] = x.shape()[static_cast<size_t>(k)]; }
      ut::Tensor mu = x.mean(ax, true), var = x.var(ax, true);
      ut::Tensor y = (x - mu) / ut::sqrt(var + n.attr_float("epsilon", 1e-5)) * arg(1).reshape(ps);
      if (has(2)) y = y + arg(2).reshape(ps);
      out = y;
    }
    else throw Error(op + ": no lowering");
  }
  if (out.shape() != v.shape || out.dtype() != v.dtype)
    throw Error("lowering of " + v.name + " gave " + name(out.dtype()) + to_string(out.shape()) + ", expected " + name(v.dtype) + to_string(v.shape));
  memo_[id] = out;
  return out;
}

std::vector<Array> Evaluator::eval(const Bindings& b, const std::vector<int>& outputs, const std::map<std::string, Array>& feeds) {
  std::string key;  // the bindings in name order, each name length-prefixed so that no two keys are alike
  for (const auto& kv : b) key += std::to_string(kv.first.size()) + ":" + kv.first + "=" + std::to_string(kv.second) + ";";
  auto it = cache_.find(key);
  if (it == cache_.end()) it = cache_.emplace(key, std::unique_ptr<Entry>(new Entry(g_.bind(b)))).first;
  Entry& e = *it->second;
  for (int in : e.bound.inputs()) {
    const Value& v = e.bound.value(in);
    auto f = feeds.find(v.name);
    if (f != feeds.end() && (f->second.shape != v.shape || f->second.dtype != v.dtype))
      throw Error("hir: the feed for " + v.name + " is " + name(f->second.dtype) + to_string(f->second.shape) + ", the bound graph needs " + name(v.dtype) + to_string(v.shape));
  }
  std::vector<ut::Tensor> ts;
  for (int o : outputs) ts.push_back(e.low.get(o));
  return e.s.eval_all(ts, feeds);
}

}  // namespace hir
}  // namespace nfcuop
