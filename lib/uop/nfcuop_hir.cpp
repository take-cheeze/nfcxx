// nfcuop::hir: the ONNX-style graph, shape inference and the ONNX exporter. See nfcuop_hir.hpp.
#include "nfcuop_hir.hpp"

#include <algorithm>
#include <cstring>
#include <set>

namespace nfcuop {
namespace hir {

const Attribute* Node::attr(const std::string& n) const {
  for (const Attribute& a : attrs) if (a.name == n) return &a;
  return nullptr;
}
int64_t Node::attr_int(const std::string& n, int64_t dflt) const {
  const Attribute* a = attr(n);
  return a ? a->i : dflt;
}
double Node::attr_float(const std::string& n, double dflt) const {
  const Attribute* a = attr(n);
  return a ? a->f : static_cast<float>(dflt);
}
std::vector<int64_t> Node::attr_ints(const std::string& n) const {
  const Attribute* a = attr(n);
  return a ? a->ints : std::vector<int64_t>{};
}

int onnx_dtype(DType d) {
  switch (d) {
    case DType::Float32: return 1;
    case DType::Int32: return 6;
    case DType::Int64: return 7;
    case DType::Bool: return 9;
    case DType::Float64: return 11;
  }
  return 0;
}
static bool dtype_from_onnx(int64_t t, DType& d) {
  switch (t) {
    case 1: d = DType::Float32; return true;
    case 6: d = DType::Int32; return true;
    case 7: d = DType::Int64; return true;
    case 9: d = DType::Bool; return true;
    case 11: d = DType::Float64; return true;
  }
  return false;
}

// ---- the graph ----

int Graph::new_value(const std::string& name_in, DType d, const Shape& shape) {
  int id = static_cast<int>(values_.size());
  std::string name = name_in.empty() ? "v" + std::to_string(id) : name_in;
  if (name_in.empty()) while (names_.count(name)) name += "_";  // an automatic name never collides with a user's
  else if (names_.count(name)) throw Error("hir: duplicate value name " + name);
  names_[name] = id;
  values_.push_back(Value{name, d, shape});
  producer_.push_back(-1);
  return id;
}

int Graph::add_input(const std::string& name, DType d, const Shape& shape) {
  if (name.empty()) throw Error("hir: an input needs a name");
  for (int64_t k : shape) if (k < 1) throw Error("hir: input " + name + " has a dimension below 1");
  int id = new_value(name, d, shape);
  inputs_.push_back(id);
  return id;
}

int Graph::add_initializer(const std::string& name, const Array& a) {
  if (static_cast<int64_t>(a.data.size()) != numel(a.shape)) throw Error("hir: initializer data does not match its shape");
  int id = new_value(name, a.dtype, a.shape);
  inits_[id] = a;
  return id;
}

const Value& Graph::value(int id) const {
  if (id < 0 || id >= static_cast<int>(values_.size())) throw Error("hir: no value " + std::to_string(id));
  return values_[id];
}
const Array* Graph::initializer(int id) const {
  auto it = inits_.find(id);
  return it == inits_.end() ? nullptr : &it->second;
}
int Graph::find_value(const std::string& n) const {
  auto it = names_.find(n);
  return it == names_.end() ? -1 : it->second;
}
int Graph::producer(int id) const { return producer_.at(static_cast<size_t>(id)); }

std::vector<int64_t> Graph::const_ints(int id) const {
  const Array* a = initializer(id);
  if (!a || !(a->dtype == DType::Int64 || a->dtype == DType::Int32)) throw Error("hir: " + value(id).name + " must be an int32 or int64 initializer");
  std::vector<int64_t> out;
  for (const Scalar& s : a->data) out.push_back(s.i);
  return out;
}

// ---- shape inference ----

namespace {

Shape bcast2(const std::string& op, const Shape& a, const Shape& b) {
  size_t n = std::max(a.size(), b.size());
  Shape out(n);
  for (size_t k = 0; k < n; k++) {
    int64_t da = k < n - a.size() ? 1 : a[k - (n - a.size())];
    int64_t db = k < n - b.size() ? 1 : b[k - (n - b.size())];
    if (da != db && da != 1 && db != 1) throw Error(op + ": shapes " + to_string(a) + " and " + to_string(b) + " cannot be broadcast together");
    out[k] = da == 1 ? db : da;
  }
  return out;
}

int64_t norm(const std::string& op, int64_t axis, int64_t rank) {
  if (axis < -rank || axis >= rank) throw Error(op + ": axis " + std::to_string(axis) + " is out of range for rank " + std::to_string(rank));
  return axis < 0 ? axis + rank : axis;
}

// The spatial attributes of Conv and the pooling operators (ONNX): one value per spatial axis for strides and dilations
// (default 1), and pads as ONNX lists them (the begin of every axis, then the ends; default 0). auto_pad must be NOTSET:
// SAME_UPPER, SAME_LOWER and VALID are refused rather than guessed.
std::vector<int64_t> per_axis(const Node& n, const std::string& attr, size_t count, int64_t dflt, bool positive) {
  std::vector<int64_t> v = n.attr_ints(attr);
  if (v.empty()) return std::vector<int64_t>(count, dflt);
  if (v.size() != count) throw Error(n.op + ": " + attr + " has " + std::to_string(v.size()) + " entries, expected " + std::to_string(count));
  for (int64_t x : v)
    if (positive ? x < 1 : x < 0) throw Error(n.op + ": " + attr + " has the entry " + std::to_string(x) + ", which is out of range");
  return v;
}

struct Window {
  Shape strides, dilations, pads_begin, pads_end;
  Shape out;  // the spatial output shape
};

// Output sizes per ONNX: floor((in + pad_begin + pad_end - dilation*(kernel-1) - 1) / stride) + 1. ceil_mode=1 is accepted only
// where it gives the same size (ONNX's ceil formula, including its last-window correction); otherwise it is refused.
Window window(const Node& n, const Shape& in, const Shape& kernel, bool ceil_mode) {
  if (n.has_attr("auto_pad") && n.attr("auto_pad")->s != "NOTSET")
    throw Error(n.op + ": auto_pad " + n.attr("auto_pad")->s + " is not supported (give pads)");
  const size_t d = in.size();
  Window w;
  w.strides = per_axis(n, "strides", d, 1, true);
  w.dilations = per_axis(n, "dilations", d, 1, true);
  Shape pads = per_axis(n, "pads", 2 * d, 0, false);
  w.pads_begin.assign(pads.begin(), pads.begin() + static_cast<std::ptrdiff_t>(d));
  w.pads_end.assign(pads.begin() + static_cast<std::ptrdiff_t>(d), pads.end());
  for (size_t k = 0; k < d; k++) {
    const int64_t extent = w.dilations[k] * (kernel[k] - 1) + 1;
    const int64_t span = in[k] + w.pads_begin[k] + w.pads_end[k] - extent;
    if (span < 0) throw Error(n.op + ": the kernel (extent " + std::to_string(extent) + ") does not fit in axis " + std::to_string(k) + " of size " + std::to_string(in[k]) + " with its pads");
    const int64_t floor_out = span / w.strides[k] + 1;
    if (ceil_mode) {
      int64_t ceil_out = (span + w.strides[k] - 1) / w.strides[k] + 1;
      if ((ceil_out - 1) * w.strides[k] >= in[k] + w.pads_begin[k]) ceil_out--;
      if (ceil_out != floor_out) throw Error(n.op + ": ceil_mode=1 changes the output size of axis " + std::to_string(k) + "; only ceil_mode=0 is supported");
    }
    w.out.push_back(floor_out);
  }
  return w;
}

// Gemm's C input: unidirectional broadcasting to `out` (C is at most 2-D and each of its dimensions is 1 or the same)
bool broadcasts_to(const Shape& c, const Shape& out) {
  if (c.size() > out.size()) return false;
  for (size_t k = 0; k < c.size(); k++) {
    int64_t dc = c[c.size() - 1 - k], dout = out[out.size() - 1 - k];
    if (dc != 1 && dc != dout) return false;
  }
  return true;
}

Value infer(const Graph& g, const Node& n) {
  const std::string& op = n.op;
  auto fail = [&](const std::string& why) -> Value { throw Error(op + ": " + why); };
  auto V = [&](size_t k) -> const Value& {
    if (k >= n.inputs.size() || n.inputs[k] < 0) throw Error(op + ": missing input " + std::to_string(k));
    return g.value(n.inputs[k]);
  };
  auto present = [&](size_t k) { return k < n.inputs.size() && n.inputs[k] >= 0; };
  auto want_inputs = [&](size_t lo, size_t hi) {
    if (n.inputs.size() < lo || n.inputs.size() > hi) throw Error(op + ": expects " + std::to_string(lo) + (hi != lo ? ".." + std::to_string(hi) : "") + " inputs, got " + std::to_string(n.inputs.size()));
  };
  auto same_dtype = [&](const Value& a, const Value& b) {
    if (a.dtype != b.dtype) throw Error(op + ": input dtypes differ, " + name(a.dtype) + " and " + name(b.dtype) + " (ONNX has no implicit conversion)");
  };
  auto consts = [&](size_t k) { return g.const_ints(n.inputs[k]); };

  static const std::set<std::string> float_unary = {"Sqrt", "Exp", "Log", "Sin", "Cos", "Tanh", "Sigmoid", "Erf", "Floor", "Ceil"};
  static const std::set<std::string> arith = {"Add", "Sub", "Mul", "Div", "Max", "Min"};
  static const std::set<std::string> logical = {"And", "Or", "Xor"};
  static const std::set<std::string> bitwise = {"BitwiseAnd", "BitwiseOr", "BitwiseXor"};
  static const std::set<std::string> compare = {"Less", "Greater", "LessOrEqual", "GreaterOrEqual"};
  static const std::set<std::string> reduces = {"ReduceSum", "ReduceMean", "ReduceMax", "ReduceMin", "ReduceProd"};

  if (op == "Identity") { want_inputs(1, 1); return Value{"", V(0).dtype, V(0).shape}; }
  if (op == "Neg" || op == "Abs" || op == "Relu") {
    want_inputs(1, 1);
    if (V(0).dtype == DType::Bool) fail("not defined for bool");
    return Value{"", V(0).dtype, V(0).shape};
  }
  if (float_unary.count(op)) {
    want_inputs(1, 1);
    if (!is_float(V(0).dtype)) fail("float input needed, got " + std::string(name(V(0).dtype)));
    return Value{"", V(0).dtype, V(0).shape};
  }
  if (op == "IsNaN" || op == "IsInf") {
    want_inputs(1, 1);
    if (!is_float(V(0).dtype)) fail("float input needed, got " + std::string(name(V(0).dtype)));
    return Value{"", DType::Bool, V(0).shape};
  }
  if (op == "ArgMax" || op == "ArgMin") {   // int64 indices; axis (default 0), keepdims (1), select_last_index (0)
    want_inputs(1, 1);
    const Value& x = V(0);
    if (x.dtype == DType::Bool) fail("not defined for bool");
    const int64_t ax = norm(op, n.attr_int("axis", 0), static_cast<int64_t>(x.shape.size()));
    for (const char* a : {"keepdims", "select_last_index"}) {
      const int64_t f = n.attr_int(a, a[0] == 'k' ? 1 : 0);
      if (f != 0 && f != 1) fail(std::string(a) + " must be 0 or 1");
    }
    const bool keep = n.attr_int("keepdims", 1) != 0;
    Shape out;
    for (size_t k = 0; k < x.shape.size(); k++) {
      if (static_cast<int64_t>(k) != ax) out.push_back(x.shape[k]);
      else if (keep) out.push_back(1);
    }
    return Value{"", DType::Int64, out};
  }
  if (op == "CumSum") {   // the axis is a constant: a scalar (or one element) of int32 or int64
    want_inputs(2, 2);
    const Value& x = V(0);
    if (x.dtype == DType::Bool) fail("not defined for bool");
    if (V(1).dtype != DType::Int32 && V(1).dtype != DType::Int64) fail("axis must be int32 or int64");
    if (numel(V(1).shape) != 1 || V(1).shape.size() > 1) fail("axis must be a scalar");
    norm(op, consts(1).at(0), static_cast<int64_t>(x.shape.size()));   // out of range is an error
    for (const char* a : {"exclusive", "reverse"}) {
      const int64_t f = n.attr_int(a, 0);
      if (f != 0 && f != 1) fail(std::string(a) + " must be 0 or 1");
    }
    return Value{"", x.dtype, x.shape};
  }
  if (op == "Pow") {
    want_inputs(2, 2);
    same_dtype(V(0), V(1));   // ONNX allows another type for the exponent; hir does not convert, so the operands must agree
    if (V(0).dtype == DType::Bool) fail("not defined for bool");
    return Value{"", V(0).dtype, bcast2(op, V(0).shape, V(1).shape)};
  }
  if (op == "Not") {
    want_inputs(1, 1);
    if (V(0).dtype != DType::Bool) fail("bool input needed");
    return Value{"", DType::Bool, V(0).shape};
  }
  if (op == "Cast") {
    want_inputs(1, 1);
    DType to;
    if (!n.has_attr("to") || !dtype_from_onnx(n.attr_int("to", 0), to)) fail("attribute `to` must be FLOAT(1), INT32(6), INT64(7), BOOL(9) or DOUBLE(11)");
    return Value{"", to, V(0).shape};
  }
  if (arith.count(op) || op == "Mod" || logical.count(op) || bitwise.count(op) || op == "Equal" || compare.count(op)) {
    want_inputs(2, 2);
    const Value &a = V(0), &b = V(1);
    same_dtype(a, b);
    DType out = a.dtype;
    if (arith.count(op) || compare.count(op)) { if (a.dtype == DType::Bool) fail("not defined for bool"); }
    if (op == "Mod") {
      if (!is_int(a.dtype)) fail("integers only (floats would need fmod=1 and are not supported)");
      int64_t f = n.attr_int("fmod", 0);
      if (f != 0 && f != 1) fail("fmod must be 0 or 1");
    }
    if (logical.count(op) && a.dtype != DType::Bool) fail("bool inputs needed (use the Bitwise operators for integers)");
    if (bitwise.count(op) && !is_int(a.dtype)) fail("integer inputs needed");
    if (op == "Equal" || compare.count(op)) out = DType::Bool;
    return Value{"", out, bcast2(op, a.shape, b.shape)};
  }
  if (op == "Where") {
    want_inputs(3, 3);
    if (V(0).dtype != DType::Bool) fail("the condition must be bool");
    same_dtype(V(1), V(2));
    return Value{"", V(1).dtype, bcast2(op, bcast2(op, V(0).shape, V(1).shape), V(2).shape)};
  }
  if (op == "Clip") {
    want_inputs(1, 3);
    for (size_t k = 1; k < 3; k++)
      if (present(k)) {
        same_dtype(V(0), V(k));
        if (!V(k).shape.empty()) fail("min and max must be scalars");
      }
    if (V(0).dtype == DType::Bool) fail("not defined for bool");
    return Value{"", V(0).dtype, V(0).shape};
  }
  if (op == "MatMul") {
    want_inputs(2, 2);
    const Value &a = V(0), &b = V(1);
    same_dtype(a, b);
    if (a.dtype == DType::Bool) fail("not defined for bool");
    if (a.shape.empty() || b.shape.empty()) fail("operands must be at least 1-D");
    const bool a1 = a.shape.size() == 1, b1 = b.shape.size() == 1;
    Shape sa = a1 ? Shape{1, a.shape[0]} : a.shape, sb = b1 ? Shape{b.shape[0], 1} : b.shape;
    if (sa.back() != sb[sb.size() - 2]) fail("shapes " + to_string(a.shape) + " and " + to_string(b.shape) + " do not align");
    Shape out = bcast2(op, Shape(sa.begin(), sa.end() - 2), Shape(sb.begin(), sb.end() - 2));
    if (!a1) out.push_back(sa[sa.size() - 2]);
    if (!b1) out.push_back(sb.back());
    return Value{"", a.dtype, out};
  }
  if (op == "Transpose") {
    want_inputs(1, 1);
    const Shape& s = V(0).shape;
    std::vector<int64_t> perm;
    if (const Attribute* p = n.attr("perm")) perm = p->ints;
    else for (size_t k = s.size(); k-- > 0;) perm.push_back(static_cast<int64_t>(k));
    std::vector<bool> seen(s.size(), false);
    if (perm.size() != s.size()) fail("perm " + to_string(perm) + " does not match rank " + std::to_string(s.size()));
    Shape out;
    for (int64_t p : perm) {
      if (p < 0 || p >= static_cast<int64_t>(s.size()) || seen[p]) fail("perm " + to_string(perm) + " is not a permutation");
      seen[p] = true;
      out.push_back(s[p]);
    }
    return Value{"", V(0).dtype, out};
  }
  if (op == "Reshape") {
    want_inputs(2, 2);
    std::vector<int64_t> target = consts(1);
    const Shape& in = V(0).shape;
    const bool allowzero = n.attr_int("allowzero", 0) != 0;
    int64_t known = 1, unknown = -1;
    for (size_t k = 0; k < target.size(); k++) {
      if (target[k] == 0 && !allowzero) {
        if (k >= in.size()) fail("a 0 in the shape copies a dimension the input does not have");
        target[k] = in[k];
      }
      if (target[k] == -1) {
        if (unknown >= 0) fail("only one dimension may be -1");
        unknown = static_cast<int64_t>(k);
      } else if (target[k] < 1) {
        fail("bad dimension in shape " + to_string(target));
      } else {
        known *= target[k];
      }
    }
    if (unknown >= 0) {
      if (numel(in) % known) fail("cannot reshape " + to_string(in) + " into " + to_string(target));
      target[unknown] = numel(in) / known;
    } else if (known != numel(in)) {
      fail("cannot reshape " + to_string(in) + " into " + to_string(target));
    }
    return Value{"", V(0).dtype, target};
  }
  if (op == "Squeeze") {
    want_inputs(1, 2);
    const Shape& in = V(0).shape;
    std::set<int64_t> axes;
    if (present(1)) for (int64_t a : consts(1)) axes.insert(norm(op, a, static_cast<int64_t>(in.size())));
    Shape out;
    for (size_t k = 0; k < in.size(); k++) {
      bool drop = present(1) ? axes.count(static_cast<int64_t>(k)) != 0 : in[k] == 1;
      if (drop && in[k] != 1) fail("cannot squeeze axis " + std::to_string(k) + " of shape " + to_string(in));
      if (!drop) out.push_back(in[k]);
    }
    return Value{"", V(0).dtype, out};
  }
  if (op == "Unsqueeze") {
    want_inputs(2, 2);
    const Shape& in = V(0).shape;
    std::vector<int64_t> axes = consts(1);
    int64_t rank = static_cast<int64_t>(in.size() + axes.size());
    std::set<int64_t> at;
    for (int64_t a : axes) if (!at.insert(norm(op, a, rank)).second) fail("repeated axis");
    Shape out;
    size_t src = 0;
    for (int64_t k = 0; k < rank; k++) out.push_back(at.count(k) ? 1 : in[src++]);
    return Value{"", V(0).dtype, out};
  }
  if (op == "Expand") {
    want_inputs(2, 2);
    std::vector<int64_t> target = consts(1);
    for (int64_t d : target) if (d < 1) fail("bad dimension in shape " + to_string(target));
    return Value{"", V(0).dtype, bcast2(op, V(0).shape, target)};
  }
  if (reduces.count(op)) {
    want_inputs(1, 2);
    const Value& x = V(0);
    if (x.dtype == DType::Bool) fail("not defined for bool");
    if (op == "ReduceMean" && !is_float(x.dtype)) fail("float input needed");
    const int64_t rank = static_cast<int64_t>(x.shape.size());
    std::set<int64_t> axes;
    if (present(1)) for (int64_t a : consts(1)) axes.insert(norm(op, a, rank));
    if (!present(1) || axes.empty()) for (int64_t k = 0; k < rank; k++) axes.insert(k);
    const bool keep = n.attr_int("keepdims", 1) != 0;
    Shape out;
    for (int64_t k = 0; k < rank; k++) {
      if (!axes.count(k)) out.push_back(x.shape[k]);
      else if (keep) out.push_back(1);
    }
    return Value{"", x.dtype, out};
  }
  if (op == "Softmax" || op == "LogSoftmax") {
    want_inputs(1, 1);
    if (!is_float(V(0).dtype)) fail("float input needed");
    norm(op, n.attr_int("axis", -1), static_cast<int64_t>(V(0).shape.size()));
    return Value{"", V(0).dtype, V(0).shape};
  }
  if (op == "Slice") {
    want_inputs(3, 5);
    const Shape& in = V(0).shape;
    std::vector<int64_t> starts = consts(1), ends = consts(2), axes, steps;
    if (present(3)) axes = consts(3); else for (size_t k = 0; k < starts.size(); k++) axes.push_back(static_cast<int64_t>(k));
    if (present(4)) steps = consts(4); else steps.assign(starts.size(), 1);
    if (starts.size() != ends.size() || starts.size() != axes.size() || starts.size() != steps.size()) fail("starts, ends, axes and steps differ in length");
    Shape out = in;
    std::set<int64_t> seen;
    for (size_t k = 0; k < starts.size(); k++) {
      int64_t ax = norm(op, axes[k], static_cast<int64_t>(in.size()));
      if (!seen.insert(ax).second) fail("repeated axis");
      if (steps[k] == 0) fail("step cannot be 0");
      SliceIdx ix = slice_indices(in[ax], true, starts[k], true, ends[k], steps[k]);
      if (ix.count < 1) fail("the slice of axis " + std::to_string(ax) + " is empty (empty tensors are not supported)");
      out[ax] = ix.count;
    }
    return Value{"", V(0).dtype, out};
  }
  if (op == "Pad") {
    want_inputs(2, 3);
    const Shape& in = V(0).shape;
    if (const Attribute* m = n.attr("mode")) if (m->s != "constant") fail("only mode constant is supported");
    std::vector<int64_t> pads = consts(1);
    if (pads.size() != 2 * in.size()) fail("pads must have 2 * rank = " + std::to_string(2 * in.size()) + " entries, got " + std::to_string(pads.size()));
    if (present(2)) {
      same_dtype(V(0), V(2));
      if (!V(2).shape.empty()) fail("constant_value must be a scalar");
      if (g.initializer(n.inputs[2]) == nullptr) fail("constant_value must be an initializer");
    }
    Shape out = in;
    for (size_t k = 0; k < in.size(); k++) {
      if (pads[k] < 0 || pads[k + in.size()] < 0) fail("negative pads (cropping) are not supported");
      out[k] += pads[k] + pads[k + in.size()];
    }
    return Value{"", V(0).dtype, out};
  }
  if (op == "Concat") {
    want_inputs(1, 1000);
    if (!n.has_attr("axis")) fail("attribute axis is required");
    const int64_t rank = static_cast<int64_t>(V(0).shape.size());
    const int64_t axis = norm(op, n.attr_int("axis", 0), rank);
    Shape out = V(0).shape;
    int64_t total = 0;
    for (size_t k = 0; k < n.inputs.size(); k++) {
      same_dtype(V(0), V(k));
      if (static_cast<int64_t>(V(k).shape.size()) != rank) fail("inputs differ in rank");
      for (int64_t d = 0; d < rank; d++)
        if (d != axis && V(k).shape[d] != out[d]) fail("shapes " + to_string(V(0).shape) + " and " + to_string(V(k).shape) + " differ off the axis");
      total += V(k).shape[axis];
    }
    out[axis] = total;
    return Value{"", V(0).dtype, out};
  }
  if (op == "Gemm") {
    want_inputs(2, 3);
    const Value &a = V(0), &b = V(1);
    if (!is_float(a.dtype)) fail("float inputs needed, got " + std::string(name(a.dtype)));
    same_dtype(a, b);
    if (present(2)) same_dtype(a, V(2));
    if (a.shape.size() != 2 || b.shape.size() != 2) fail("A and B must be 2-D, got " + to_string(a.shape) + " and " + to_string(b.shape));
    const int64_t tA = n.attr_int("transA", 0), tB = n.attr_int("transB", 0);
    if ((tA != 0 && tA != 1) || (tB != 0 && tB != 1)) fail("transA and transB must be 0 or 1");
    const Shape A = tA ? Shape{a.shape[1], a.shape[0]} : a.shape;
    const Shape B = tB ? Shape{b.shape[1], b.shape[0]} : b.shape;
    if (A[1] != B[0]) fail("op(A) " + to_string(A) + " and op(B) " + to_string(B) + " do not align");
    const Shape out{A[0], B[1]};
    if (present(2) && !broadcasts_to(V(2).shape, out)) fail("C " + to_string(V(2).shape) + " does not broadcast to " + to_string(out));
    return Value{"", a.dtype, out};
  }
  if (op == "Gather") {
    want_inputs(2, 2);
    const Value &d = V(0), &ix = V(1);
    if (d.dtype == DType::Bool) fail("bool data is not supported");
    if (ix.dtype != DType::Int32 && ix.dtype != DType::Int64) fail("indices must be int32 or int64, got " + std::string(name(ix.dtype)));
    const int64_t r = static_cast<int64_t>(d.shape.size());
    if (r < 1) fail("data must be at least 1-D");
    const int64_t ax = norm(op, n.attr_int("axis", 0), r);
    if (const Array* c = g.initializer(n.inputs[1]))   // constant indices are checked now; runtime ones cannot be
      for (const Scalar& s : c->data)
        if (s.i < -d.shape[ax] || s.i >= d.shape[ax]) fail("index " + std::to_string(s.i) + " is out of range for axis " + std::to_string(ax) + " of size " + std::to_string(d.shape[ax]));
    Shape out(d.shape.begin(), d.shape.begin() + ax);
    out.insert(out.end(), ix.shape.begin(), ix.shape.end());
    out.insert(out.end(), d.shape.begin() + ax + 1, d.shape.end());
    return Value{"", d.dtype, out};
  }
  if (op == "Conv") {
    want_inputs(2, 3);
    const Value &x = V(0), &w = V(1);
    if (!is_float(x.dtype)) fail("float inputs needed, got " + std::string(name(x.dtype)));
    same_dtype(x, w);
    if (present(2)) same_dtype(x, V(2));
    if (x.shape.size() < 3) fail("X must be (N, C, D1, ...) with at least one spatial axis, got " + to_string(x.shape));
    if (w.shape.size() != x.shape.size()) fail("W " + to_string(w.shape) + " must have the rank of X " + to_string(x.shape));
    const int64_t group = n.attr_int("group", 1), C = x.shape[1], M = w.shape[0];
    if (group < 1 || C % group != 0 || M % group != 0) fail("group " + std::to_string(group) + " must divide the channels C=" + std::to_string(C) + " and M=" + std::to_string(M));
    if (w.shape[1] != C / group) fail("W has " + std::to_string(w.shape[1]) + " input channels per group, expected C/group = " + std::to_string(C / group));
    Shape kernel(w.shape.begin() + 2, w.shape.end());
    if (n.has_attr("kernel_shape") && n.attr_ints("kernel_shape") != kernel) fail("kernel_shape does not match the spatial shape of W " + to_string(w.shape));
    if (present(2) && V(2).shape != Shape{M}) fail("B must have shape [M] = [" + std::to_string(M) + "]");
    Window win = window(n, Shape(x.shape.begin() + 2, x.shape.end()), kernel, false);
    Shape out{x.shape[0], M};
    out.insert(out.end(), win.out.begin(), win.out.end());
    return Value{"", x.dtype, out};
  }
  if (op == "MaxPool" || op == "AveragePool") {
    want_inputs(1, 1);
    const Value& x = V(0);
    if (!is_float(x.dtype)) fail("float input needed, got " + std::string(name(x.dtype)));
    if (x.shape.size() < 3) fail("X must be (N, C, D1, ...) with at least one spatial axis, got " + to_string(x.shape));
    if (!n.has_attr("kernel_shape")) fail("attribute kernel_shape is required");
    const size_t d = x.shape.size() - 2;
    Shape kernel = per_axis(n, "kernel_shape", d, 1, true);
    if (op == "AveragePool" && n.has_attr("dilations")) fail("AveragePool has no dilations attribute");
    Window win = window(n, Shape(x.shape.begin() + 2, x.shape.end()), kernel, n.attr_int("ceil_mode", 0) != 0);
    for (size_t k = 0; k < d; k++)   // a window that lies only in the padding has no value: refused
      if (win.pads_begin[k] >= win.dilations[k] * (kernel[k] - 1) + 1 || win.pads_end[k] >= win.dilations[k] * (kernel[k] - 1) + 1)
        fail("pads of axis " + std::to_string(k) + " reach a whole window (pads must be smaller than the kernel extent)");
    Shape out{x.shape[0], x.shape[1]};
    out.insert(out.end(), win.out.begin(), win.out.end());
    return Value{"", x.dtype, out};
  }
  if (op == "BatchNormalization") {
    want_inputs(5, 5);
    const Value& x = V(0);
    if (!is_float(x.dtype)) fail("float input needed, got " + std::string(name(x.dtype)));
    if (x.shape.size() < 2) fail("X must be (N, C, D1, ...), got " + to_string(x.shape));
    if (n.attr_int("training_mode", 0) != 0) fail("training_mode=1 is not supported (inference only: training_mode=0)");
    const int64_t C = x.shape[1];
    for (size_t k = 1; k < 5; k++) {   // scale, B, input_mean, input_var: [C]
      same_dtype(x, V(k));
      if (V(k).shape != Shape{C}) fail("parameter " + std::to_string(k) + " must have shape [C] = [" + std::to_string(C) + "], got " + to_string(V(k).shape));
    }
    return Value{"", x.dtype, x.shape};
  }
  if (op == "InstanceNormalization") {
    want_inputs(3, 3);
    const Value& x = V(0);
    if (!is_float(x.dtype)) fail("float input needed, got " + std::string(name(x.dtype)));
    if (x.shape.size() < 3) fail("input must be (N, C, D1, ...) with at least one spatial axis, got " + to_string(x.shape));
    const int64_t C = x.shape[1];
    for (size_t k = 1; k < 3; k++) {   // scale, B: [C]
      same_dtype(x, V(k));
      if (V(k).shape != Shape{C}) fail("scale and B must have shape [C] = [" + std::to_string(C) + "], got " + to_string(V(k).shape));
    }
    return Value{"", x.dtype, x.shape};
  }
  if (op == "LayerNormalization") {
    want_inputs(2, 3);
    const Value& x = V(0);
    if (!is_float(x.dtype)) fail("float input needed, got " + std::string(name(x.dtype)));
    const int64_t r = static_cast<int64_t>(x.shape.size());
    const int64_t axis = norm(op, n.attr_int("axis", -1), r);
    const Shape normalized(x.shape.begin() + axis, x.shape.end());   // Scale and B have this shape
    same_dtype(x, V(1));
    if (V(1).shape != normalized) fail("Scale must have the normalized shape " + to_string(normalized) + ", got " + to_string(V(1).shape));
    if (present(2)) {
      same_dtype(x, V(2));
      if (V(2).shape != normalized) fail("B must have the normalized shape " + to_string(normalized) + ", got " + to_string(V(2).shape));
    }
    return Value{"", x.dtype, x.shape};
  }
  return fail("unsupported operator");
}

}  // namespace

int Graph::add_node(const std::string& op, std::vector<int> inputs, std::vector<Attribute> attrs, const std::string& out_name) {
  return add_node_named(op, std::move(inputs), std::move(attrs), out_name, "");
}

int Graph::add_node_named(const std::string& op, std::vector<int> inputs, std::vector<Attribute> attrs, const std::string& out_name, const std::string& node_name) {
  Node n;
  n.op = op;
  n.inputs = std::move(inputs);
  n.attrs = std::move(attrs);
  for (int in : n.inputs) if (in >= static_cast<int>(values_.size()) || in < -1) throw Error(op + ": no such input value " + std::to_string(in));
  while (!n.inputs.empty() && n.inputs.back() < 0) n.inputs.pop_back();  // trailing omitted optionals
  Value v = infer(*this, n);
  n.output = new_value(out_name, v.dtype, v.shape);
  n.name = node_name.empty() || node_names_.count(node_name) ? "node_" + std::to_string(nodes_.size()) : node_name;   // an imported node keeps its name
  while (node_names_.count(n.name)) n.name += "_";
  node_names_[n.name] = 1;
  producer_[n.output] = static_cast<int>(nodes_.size());
  nodes_.push_back(std::move(n));
  return nodes_.back().output;
}

// ---- text ----

std::string Graph::str() const {
  std::string out;
  for (int in : inputs_) out += "input %" + values_[in].name + " : " + name(values_[in].dtype) + to_string(values_[in].shape) + "\n";
  for (const auto& kv : inits_) out += "const %" + values_[kv.first].name + " : " + name(kv.second.dtype) + to_string(kv.second.shape) + "\n";
  for (const Node& n : nodes_) {
    out += "%" + values_[n.output].name + " = " + n.op + "(";
    for (size_t k = 0; k < n.inputs.size(); k++) out += (k ? ", " : "") + (n.inputs[k] < 0 ? std::string("_") : "%" + values_[n.inputs[k]].name);
    out += ")";
    for (const Attribute& a : n.attrs) {
      out += " " + a.name + "=";
      if (a.kind == AttrKind::Int) out += std::to_string(a.i);
      else if (a.kind == AttrKind::Ints) out += to_string(a.ints);
      else if (a.kind == AttrKind::Float) out += std::to_string(a.f);
      else if (a.kind == AttrKind::Floats) { out += "["; for (size_t k = 0; k < a.floats.size(); k++) out += (k ? "," : "") + std::to_string(a.floats[k]); out += "]"; }
      else if (a.kind == AttrKind::Tensor) out += std::string(name(a.t.dtype)) + to_string(a.t.shape);
      else out += "\"" + a.s + "\"";
    }
    out += " : " + std::string(name(values_[n.output].dtype)) + to_string(values_[n.output].shape) + "\n";
  }
  return out;
}

// ---- ONNX export (a hand-written protobuf writer for the few messages needed) ----

namespace {

struct PB {
  std::string b;
  void varint(uint64_t v) {
    while (v >= 0x80) { b.push_back(static_cast<char>(v | 0x80)); v >>= 7; }
    b.push_back(static_cast<char>(v));
  }
  void tag(int field, int wire) { varint(static_cast<uint64_t>(field) << 3 | static_cast<uint64_t>(wire)); }
  void i64(int field, int64_t v) { tag(field, 0); varint(static_cast<uint64_t>(v)); }
  void f32(int field, float v) { tag(field, 5); b.append(reinterpret_cast<const char*>(&v), 4); }
  void bytes(int field, const std::string& s) { tag(field, 2); varint(s.size()); b += s; }
  void msg(int field, const PB& m) { bytes(field, m.b); }
};

std::string raw_data(const Array& a) {
  std::string out;
  for (const Scalar& s : a.data) {
    switch (a.dtype) {
      case DType::Bool: out.push_back(s.i ? 1 : 0); break;
      case DType::Int32: { int32_t v = static_cast<int32_t>(s.i); out.append(reinterpret_cast<const char*>(&v), 4); break; }
      case DType::Int64: { int64_t v = s.i; out.append(reinterpret_cast<const char*>(&v), 8); break; }
      case DType::Float32: { float v = static_cast<float>(s.f); out.append(reinterpret_cast<const char*>(&v), 4); break; }
      case DType::Float64: { double v = s.f; out.append(reinterpret_cast<const char*>(&v), 8); break; }
    }
  }
  return out;
}

// A TensorProto: dims, data_type, name (if any) and raw_data.
PB tensor_proto(const std::string& name, const Array& a) {
  PB t;
  for (int64_t d : a.shape) t.i64(1, d);
  t.i64(2, onnx_dtype(a.dtype));
  if (!name.empty()) t.bytes(8, name);
  t.bytes(9, raw_data(a));
  return t;
}

PB value_info(const Value& v) {
  PB dims;
  for (int64_t d : v.shape) {
    PB dim;
    dim.i64(1, d);  // dim_value
    dims.msg(1, dim);
  }
  PB tensor;
  tensor.i64(1, onnx_dtype(v.dtype));
  tensor.msg(2, dims);
  PB type;
  type.msg(1, tensor);
  PB vi;
  vi.bytes(1, v.name);
  vi.msg(2, type);
  return vi;
}

}  // namespace

std::string Graph::to_onnx(const std::vector<int>& outputs, const std::string& graph_name) const {
  if (outputs.empty()) throw Error("hir: to_onnx needs at least one output");
  std::set<int> need_values(outputs.begin(), outputs.end());
  if (need_values.size() != outputs.size()) throw Error("hir: to_onnx outputs must be distinct");
  for (int o : outputs) {
    value(o);
    if (producer_[o] < 0) throw Error("hir: output " + values_[o].name + " is an input or an initializer; pass it through Identity");
  }
  std::vector<bool> need_node(nodes_.size(), false);
  for (size_t k = nodes_.size(); k-- > 0;) {  // nodes are in topological order
    if (!need_values.count(nodes_[k].output)) continue;
    need_node[k] = true;
    for (int in : nodes_[k].inputs) if (in >= 0) need_values.insert(in);
  }
  PB graph;
  for (size_t k = 0; k < nodes_.size(); k++) {
    if (!need_node[k]) continue;
    const Node& n = nodes_[k];
    PB node;
    for (int in : n.inputs) node.bytes(1, in < 0 ? "" : values_[in].name);
    node.bytes(2, values_[n.output].name);
    node.bytes(3, n.name);
    node.bytes(4, n.op);
    for (const Attribute& a : n.attrs) {
      PB at;
      at.bytes(1, a.name);
      if (a.kind == AttrKind::Int) { at.i64(3, a.i); at.i64(20, 2); }
      else if (a.kind == AttrKind::Ints) { for (int64_t v : a.ints) at.i64(8, v); at.i64(20, 7); }
      else if (a.kind == AttrKind::String) { at.bytes(4, a.s); at.i64(20, 3); }
      else if (a.kind == AttrKind::Float) { at.f32(2, static_cast<float>(a.f)); at.i64(20, 1); }
      else if (a.kind == AttrKind::Floats) { for (double v : a.floats) at.f32(7, static_cast<float>(v)); at.i64(20, 6); }
      else { at.msg(5, tensor_proto("", a.t)); at.i64(20, 4); }
      node.msg(5, at);
    }
    graph.msg(1, node);
  }
  graph.bytes(2, graph_name);
  for (const auto& kv : inits_) {
    if (!need_values.count(kv.first)) continue;
    graph.msg(5, tensor_proto(values_[kv.first].name, kv.second));
  }
  for (int in : inputs_) if (need_values.count(in)) graph.msg(11, value_info(values_[in]));
  for (int o : outputs) graph.msg(12, value_info(values_[o]));
  PB opset;
  opset.bytes(1, "");
  opset.i64(2, 18);
  PB model;
  model.i64(1, 8);  // ir_version
  model.bytes(2, "nfcuop");
  model.msg(7, graph);
  model.msg(8, opset);
  return model.b;
}

}  // namespace hir
}  // namespace nfcuop
