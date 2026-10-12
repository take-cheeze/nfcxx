// nfcuop::hir::Lowerer: the ONNX operators of a hir::Graph as UOp tensors (nfcuop_ut.hpp). See nfcuop_hir.hpp.
#include "nfcuop_hir.hpp"

#include <algorithm>
#include <set>
#include <vector>

namespace nfcuop {
namespace hir {

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
    else if (op == "ReduceSum" || op == "ReduceMean" || op == "ReduceMax" || op == "ReduceMin") {
      ut::Axes axes = has(1) ? ints(1) : ut::Axes{};   // none: all of them
      bool keep = n.attr_int("keepdims", 1) != 0;
      ut::Tensor x = arg(0);
      out = op == "ReduceSum" ? x.sum(axes, keep) : op == "ReduceMean" ? x.mean(axes, keep) : op == "ReduceMax" ? x.max(axes, keep) : x.min(axes, keep);
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
    else throw Error(op + ": no lowering");
  }
  if (out.shape() != v.shape || out.dtype() != v.dtype)
    throw Error("lowering of " + v.name + " gave " + name(out.dtype()) + to_string(out.shape()) + ", expected " + name(v.dtype) + to_string(v.shape));
  memo_[id] = out;
  return out;
}

}  // namespace hir
}  // namespace nfcuop
