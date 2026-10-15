// nfcuop::np: the numpy-like API over the ONNX-style graph. See nfcuop_np.hpp.
#include "nfcuop_np.hpp"

#include "nfcuop_onnxgrad.hpp"
#include "nfcuop_ort.hpp"
#include "nfcuop_tinygrad.hpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>

namespace nfcuop {
namespace np {

namespace {

using hir::Attribute;

hir::Graph& H(const Tensor& t) { return t.session().graph(); }
void check(const Tensor& t) {
  if (!t.valid()) throw Error("np: use of an empty Tensor");
}
void same_session(const Tensor& a, const Tensor& b) {
  check(a);
  check(b);
  if (&a.session() != &b.session()) throw Error("np: tensors of different sessions");
}

DType promote(DType a, DType b) { return a > b ? a : b; }  // the enum is ordered bool < int32 < int64 < float32 < float64

Tensor node(const Tensor& like, const std::string& op, std::vector<int> in, std::vector<Attribute> attrs = {}) {
  return Tensor(&like.session(), H(like).add_node(op, std::move(in), std::move(attrs)));
}
Tensor node(const std::string& op, const std::vector<Tensor>& in, std::vector<Attribute> attrs = {}) {
  std::vector<int> ids;
  for (const Tensor& t : in) ids.push_back(t.id());
  return node(in.at(0), op, ids, std::move(attrs));
}

Tensor cast_to(const Tensor& t, DType d) {
  if (t.dtype() == d) return t;
  const Array* c = H(t).initializer(t.id());
  if (c && c->data.size() <= 64) {  // a small constant is converted now, not by a Cast node in the model
    Array conv(d, c->shape, {});
    for (const Scalar& v : c->data) conv.data.push_back(is_float(v.dtype) ? Scalar::from_double(d, v.f) : Scalar::from_int(d, v.i));
    return Tensor(&t.session(), t.session().constant(conv));
  }
  return node(t, "Cast", {t.id()}, {Attribute::Int("to", hir::onnx_dtype(d))});
}
Tensor to_float(const Tensor& t) { return is_float(t.dtype()) ? t : cast_to(t, t.session().default_float); }
DType int_or_default(const Tensor& like, DType d) { return d == DType::Bool ? like.session().default_int : d; }  // bool arithmetic is done in default_int

// constants, shared by content
Tensor int64_const(const Tensor& like, const std::vector<int64_t>& v) {
  Array a;
  a.dtype = DType::Int64;
  a.shape = {static_cast<int64_t>(v.size())};
  for (int64_t x : v) a.data.push_back(Scalar::from_int(DType::Int64, x));
  return Tensor(&like.session(), like.session().constant(a));
}
Tensor scalar_const(const Tensor& like, DType d, double v) {
  Array a(d, {}, {Scalar::from_double(d, v)});
  return Tensor(&like.session(), like.session().constant(a));
}
Tensor sconst(const Tensor& like, double v) { return scalar_const(like, like.dtype(), v); }  // of like's dtype

int64_t norm_axis(int64_t ax, int64_t nd) {
  if (ax < -nd || ax >= nd) throw Error("np: axis " + std::to_string(ax) + " is out of range for " + std::to_string(nd) + " dimensions");
  return ax < 0 ? ax + nd : ax;
}

Tensor int64_scalar(const Tensor& like, int64_t v) {
  Array a(DType::Int64, {}, {Scalar::from_int(DType::Int64, v)});
  return Tensor(&like.session(), like.session().constant(a));
}

Axes all_axes(int64_t nd) {
  Axes a;
  for (int64_t k = 0; k < nd; k++) a.push_back(k);
  return a;
}

Axes norm_axes(const Axes& axes, int64_t nd) {
  if (axes.empty()) return all_axes(nd);
  Axes out;
  for (int64_t a : axes) out.push_back(norm_axis(a, nd));
  std::sort(out.begin(), out.end());
  if (std::adjacent_find(out.begin(), out.end()) != out.end()) throw Error("np: repeated axis");
  return out;
}

// Operands cast to `dt`; shapes are broadcast by the ONNX operators themselves.
Tensor arith(const char* op, Tensor a, Tensor b) {  // Add Sub Mul Max Min: bool operands become int32
  same_session(a, b);
  DType dt = int_or_default(a, promote(a.dtype(), b.dtype()));
  return node(op, {cast_to(a, dt), cast_to(b, dt)});
}

Tensor compare(const char* op, Tensor a, Tensor b) {
  same_session(a, b);
  DType dt = promote(a.dtype(), b.dtype());
  if (dt == DType::Bool && std::string(op) != "Equal") dt = a.session().default_int;
  return node(op, {cast_to(a, dt), cast_to(b, dt)});
}

Tensor logic(const char* boolop, const char* intop, Tensor a, Tensor b) {
  same_session(a, b);
  DType dt = promote(a.dtype(), b.dtype());
  if (is_float(dt)) throw Error(std::string("np: ") + boolop + " is not defined for floats");
  return node(dt == DType::Bool ? boolop : intop, {cast_to(a, dt), cast_to(b, dt)});
}

Tensor bool_not(const Tensor& x) { return node(x, "Not", {x.id()}); }

DType int_dtype(const Tensor& a, const Tensor& b, const char* what) {
  DType dt = int_or_default(a, promote(a.dtype(), b.dtype()));
  if (!is_int(dt)) throw Error(std::string("np: ") + what + " is defined for integers only");
  return dt;
}

// numpy's floor semantics from C's truncation (ONNX Div and Mod with fmod=1 on ints): adjust when the remainder is
// nonzero and its sign differs from the divisor's.
Tensor floor_adjust(const Tensor& r, const Tensor& y) {
  Tensor zero = sconst(r, 0);
  Tensor nonzero = bool_not(node("Equal", {r, zero}));
  Tensor differ = node("Xor", {node("Less", {r, zero}), node("Less", {y, sconst(y, 0)})});
  return node("And", {nonzero, differ});
}

Tensor reduce(const char* op, const Tensor& x, const Axes& axes_in, bool keepdims) {
  check(x);
  Axes axes = norm_axes(axes_in, x.ndim());
  Tensor ax = int64_const(x, axes);
  return node(op, {x, ax}, {Attribute::Int("keepdims", keepdims ? 1 : 0)});
}

std::string fmt(const Scalar& s) {
  char buf[64];
  switch (s.dtype) {
    case DType::Bool: return s.i ? "True" : "False";
    case DType::Int32: case DType::Int64: std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(s.i)); return buf;
    case DType::Float32: std::snprintf(buf, sizeof buf, "%.8g", s.f); break;
    case DType::Float64: std::snprintf(buf, sizeof buf, "%.16g", s.f); break;
  }
  std::string out = buf;
  if (std::isfinite(s.f) && out.find_first_of(".e") == std::string::npos) out += ".";
  return out;
}

void print(const Array& a, size_t dim, size_t& pos, std::string& out) {
  if (dim == a.shape.size()) { out += fmt(a.data[pos++]); return; }
  out += "[";
  for (int64_t k = 0; k < a.shape[dim]; k++) {
    if (k) out += ", ";
    print(a, dim + 1, pos, out);
  }
  out += "]";
}

}  // namespace

namespace detail {
Tensor lift(const Tensor& like, double v, bool integral) {
  check(like);
  // a Python-style scalar is weak: it takes the tensor's dtype unless it is a float next to an integer tensor
  DType dt = like.dtype();
  if (is_float(dt)) { /* a float tensor keeps its dtype for int and float scalars alike */ }
  else if (!integral) dt = like.session().default_float;
  else if (dt == DType::Bool) dt = like.session().default_int;
  return scalar_const(like, dt, v);
}
}  // namespace detail

const Shape& Tensor::shape() const {
  if (!valid()) throw Error("np: use of an empty Tensor");
  return s_->graph().value(id_).shape;
}
DType Tensor::dtype() const {
  if (!valid()) throw Error("np: use of an empty Tensor");
  return s_->graph().value(id_).dtype;
}

// ---- Tensor: shape ----

Tensor Tensor::reshape(Shape shape_) const {
  check(*this);
  return node(*this, "Reshape", {id_, int64_const(*this, shape_).id()});
}

Tensor Tensor::transpose() const {
  Axes perm;
  for (int64_t k = ndim(); k-- > 0;) perm.push_back(k);
  return transpose(perm);
}

Tensor Tensor::transpose(const Axes& perm) const {
  check(*this);
  Axes p;
  for (int64_t a : perm) p.push_back(norm_axis(a, ndim()));
  return node(*this, "Transpose", {id_}, {Attribute::Ints("perm", p)});
}

Tensor Tensor::swapaxes(int64_t a, int64_t b) const {
  check(*this);
  Axes p = all_axes(ndim());
  std::swap(p[norm_axis(a, ndim())], p[norm_axis(b, ndim())]);
  return transpose(p);
}

Tensor Tensor::squeeze() const {
  check(*this);
  return node(*this, "Squeeze", {id_});
}

Tensor Tensor::squeeze(int64_t axis) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  if (shape()[axis] != 1) throw Error("np: cannot squeeze axis " + std::to_string(axis) + " of shape " + to_string(shape()));
  return node(*this, "Squeeze", {id_, int64_const(*this, {axis}).id()});
}

Tensor Tensor::expand_dims(int64_t axis) const {
  check(*this);
  axis = norm_axis(axis, ndim() + 1);
  return node(*this, "Unsqueeze", {id_, int64_const(*this, {axis}).id()});
}

Tensor Tensor::broadcast_to(const Shape& shape_) const {
  check(*this);
  Tensor r = node(*this, "Expand", {id_, int64_const(*this, shape_).id()});
  if (r.shape() != shape_) throw Error("np: cannot broadcast " + to_string(shape()) + " to " + to_string(shape_));
  return r;
}

Tensor Tensor::astype(DType d) const {
  check(*this);
  return cast_to(*this, d);
}

Tensor Tensor::slice(int64_t axis, int64_t start, int64_t stop, int64_t step) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  SliceIdx ix = slice_indices(shape()[axis], start != None, start, stop != None, stop, step);
  if (ix.count < 1) throw Error("np: the slice of axis " + std::to_string(axis) + " is empty (tensors need at least one element per dimension)");
  // concrete bounds; a negative step that runs to the front ends before index 0, which ONNX spells INT64_MIN
  int64_t end = ix.start + ix.count * ix.step;
  if (ix.step < 0 && end < 0) end = INT64_MIN;
  return node(*this, "Slice", {id_, int64_const(*this, {ix.start}).id(), int64_const(*this, {end}).id(), int64_const(*this, {axis}).id(),
                               int64_const(*this, {ix.step}).id()});
}

Tensor Tensor::at(int64_t index, int64_t axis) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  int64_t dim = shape()[axis];
  if (index < -dim || index >= dim) throw Error("np: index " + std::to_string(index) + " is out of bounds for axis " + std::to_string(axis) + " with size " + std::to_string(dim));
  if (index < 0) index += dim;
  return slice(axis, index, index + 1).squeeze(axis);
}

Tensor Tensor::flip(int64_t axis) const { return slice(axis, None, None, -1); }

// ---- Tensor: reductions ----

Tensor Tensor::sum(const Axes& axes, bool keepdims) const {
  check(*this);
  // like numpy, a sum of bool or of narrow integers is at least default_int
  DType dt = dtype();
  if (dt == DType::Bool || (is_int(dt) && dt < s_->default_int)) dt = s_->default_int;
  return reduce("ReduceSum", cast_to(*this, dt), axes, keepdims);
}

Tensor Tensor::mean(const Axes& axes, bool keepdims) const {
  check(*this);
  return reduce("ReduceMean", to_float(*this), axes, keepdims);
}

Tensor Tensor::max(const Axes& axes, bool keepdims) const {
  check(*this);
  if (dtype() != DType::Bool) return reduce("ReduceMax", *this, axes, keepdims);
  return cast_to(reduce("ReduceMax", cast_to(*this, DType::Int32), axes, keepdims), DType::Bool);  // ONNX has no bool ReduceMax
}

Tensor Tensor::min(const Axes& axes, bool keepdims) const {
  check(*this);
  if (dtype() != DType::Bool) return reduce("ReduceMin", *this, axes, keepdims);
  return cast_to(reduce("ReduceMin", cast_to(*this, DType::Int32), axes, keepdims), DType::Bool);
}

Tensor Tensor::var(const Axes& axes, bool keepdims, double correction) const {
  check(*this);
  Tensor x = to_float(*this);
  Tensor d = x - x.mean(axes, true);
  if (correction == 0) return (d * d).mean(axes, keepdims);
  double n = 1;
  for (int64_t a : norm_axes(axes, ndim())) n *= static_cast<double>(shape()[static_cast<size_t>(a)]);
  return (d * d).sum(axes, keepdims) / (n - correction);
}

Tensor Tensor::stddev(const Axes& axes, bool keepdims, double correction) const { return var(axes, keepdims, correction).sqrt(); }

Tensor Tensor::prod(const Axes& axes, bool keepdims) const {
  check(*this);
  DType dt = dtype();
  if (dt == DType::Bool || (is_int(dt) && dt < s_->default_int)) dt = s_->default_int;
  return reduce("ReduceProd", cast_to(*this, dt), axes, keepdims);
}

Tensor arg_node(const Tensor& x, const char* op, int64_t axis, bool keepdims) {
  check(x);
  Tensor src = axis == None ? x.flatten() : x;
  const int64_t ax = axis == None ? 0 : norm_axis(axis, x.ndim());
  if (src.dtype() == DType::Bool) src = cast_to(src, src.session().default_int);   // ONNX has no bool ArgMax
  Tensor r = node(src, op, {src.id()}, {Attribute::Int("axis", ax), Attribute::Int("keepdims", keepdims ? 1 : 0)});
  if (axis == None && keepdims) r = r.reshape(Shape(static_cast<size_t>(x.ndim()), 1));
  return cast_to(r, x.session().default_int);
}

Tensor Tensor::argmax(int64_t axis, bool keepdims) const { return arg_node(*this, "ArgMax", axis, keepdims); }
Tensor Tensor::argmin(int64_t axis, bool keepdims) const { return arg_node(*this, "ArgMin", axis, keepdims); }

Tensor Tensor::cumsum(int64_t axis) const {
  check(*this);
  Tensor x = axis == None ? flatten() : *this;
  const int64_t ax = axis == None ? 0 : norm_axis(axis, ndim());
  DType dt = x.dtype();
  if (dt == DType::Bool || (is_int(dt) && dt < s_->default_int)) dt = s_->default_int;
  x = cast_to(x, dt);
  return node(x, "CumSum", {x.id(), int64_scalar(x, ax).id()});
}

// ---- Tensor: elementwise ----

Tensor Tensor::operator-() const {
  check(*this);
  return node(*this, "Neg", {id_});
}

Tensor Tensor::abs() const {
  check(*this);
  return dtype() == DType::Bool ? *this : node(*this, "Abs", {id_});
}

Tensor Tensor::sqrt() const { Tensor x = to_float(*this); return node(x, "Sqrt", {x.id()}); }
Tensor Tensor::exp() const { Tensor x = to_float(*this); return node(x, "Exp", {x.id()}); }
Tensor Tensor::log() const { Tensor x = to_float(*this); return node(x, "Log", {x.id()}); }
Tensor Tensor::sin() const { Tensor x = to_float(*this); return node(x, "Sin", {x.id()}); }
Tensor Tensor::cos() const { Tensor x = to_float(*this); return node(x, "Cos", {x.id()}); }
Tensor Tensor::tanh() const { Tensor x = to_float(*this); return node(x, "Tanh", {x.id()}); }
Tensor Tensor::sigmoid() const { Tensor x = to_float(*this); return node(x, "Sigmoid", {x.id()}); }

Tensor Tensor::relu() const {
  check(*this);
  Tensor x = dtype() == DType::Bool ? cast_to(*this, s_->default_int) : *this;
  return node(x, "Relu", {x.id()});
}

Tensor Tensor::square() const {
  check(*this);
  return *this * *this;
}

Tensor Tensor::reciprocal() const {
  Tensor x = to_float(*this);
  return sconst(x, 1) / x;
}

Tensor Tensor::softmax(int64_t axis) const {
  Tensor x = to_float(*this);
  norm_axis(axis, x.ndim());
  return node(x, "Softmax", {x.id()}, {Attribute::Int("axis", axis)});
}

Tensor Tensor::log_softmax(int64_t axis) const {
  Tensor x = to_float(*this);
  norm_axis(axis, x.ndim());
  return node(x, "LogSoftmax", {x.id()}, {Attribute::Int("axis", axis)});
}

Tensor Tensor::clip(double lo, double hi) const {
  check(*this);
  Tensor x = to_float(*this);
  return node(x, "Clip", {x.id(), sconst(x, lo).id(), sconst(x, hi).id()});
}

// numpy keeps an integer's dtype (floor of int32 is int32); a bool has no float16 here and gives default_float
Tensor Tensor::floor() const {
  check(*this);
  if (is_int(dtype())) return *this;
  Tensor x = to_float(*this);
  return node(x, "Floor", {x.id()});
}
Tensor Tensor::ceil() const {
  check(*this);
  if (is_int(dtype())) return *this;
  Tensor x = to_float(*this);
  return node(x, "Ceil", {x.id()});
}

Tensor Tensor::isnan() const {
  check(*this);
  if (!is_float(dtype())) return s_->zeros(shape(), DType::Bool);   // numpy: no integer or bool is NaN
  return node(*this, "IsNaN", {id_});
}

Tensor Tensor::isinf() const {
  check(*this);
  if (!is_float(dtype())) return s_->zeros(shape(), DType::Bool);
  return node(*this, "IsInf", {id_});
}

// ---- Tensor: realization ----

Array Tensor::numpy() const {
  check(*this);
  return s_->eval(*this);
}

std::vector<double> Tensor::tolist() const {
  Array a = numpy();
  std::vector<double> out;
  for (const Scalar& s : a.data) out.push_back(s.as_double());
  return out;
}

double Tensor::item() const {
  if (size() != 1) throw Error("np: item() needs a tensor of one element, got shape " + to_string(shape()));
  return numpy().data[0].as_double();
}

std::string Tensor::str() const {
  Array a = numpy();
  std::string out;
  size_t pos = 0;
  print(a, 0, pos, out);
  return out;
}

std::string Tensor::dump() const {
  check(*this);
  return H(*this).str();
}

std::string Tensor::dump_uops() const {
  check(*this);
  return nfcuop::dump(s_->lower(*this).uop());
}

// ---- Session ----

int Session::constant(const Array& a) {
  std::string key = std::string(name(a.dtype)) + to_string(a.shape) + ":";
  if (a.data.size() <= 64) {  // small constants (scalars, shapes, axes) are shared
    for (const Scalar& s : a.data) key += to_string(s) + ",";
    auto it = consts_.find(key);
    if (it != consts_.end()) return it->second;
    int id = hir_.add_initializer("", a);
    consts_[key] = id;
    return id;
  }
  return hir_.add_initializer("", a);
}

Tensor Session::from(const Array& a) { return Tensor(this, constant(a)); }

Tensor Session::array(const std::vector<double>& v, std::optional<DType> d) {
  return array(v, Shape{static_cast<int64_t>(v.size())}, d);
}

Tensor Session::array(const std::vector<double>& v, const Shape& shape, std::optional<DType> d) {
  return from(Array::from_doubles(d ? *d : default_float, shape, v));
}

Tensor Session::array2d(const std::vector<std::vector<double>>& rows, std::optional<DType> d) {
  if (rows.empty() || rows[0].empty()) throw Error("np: array2d needs at least one element");
  std::vector<double> flat;
  for (const auto& r : rows) {
    if (r.size() != rows[0].size()) throw Error("np: array2d rows differ in length");
    flat.insert(flat.end(), r.begin(), r.end());
  }
  return array(flat, Shape{static_cast<int64_t>(rows.size()), static_cast<int64_t>(rows[0].size())}, d);
}

Tensor Session::scalar(double v, std::optional<DType> d) {
  DType t = d ? *d : default_float;
  return from(Array(t, {}, {Scalar::from_double(t, v)}));
}

Tensor Session::full_impl(const Shape& shape, double v, DType d) {
  for (int64_t k : shape) if (k < 1) throw Error("np: every dimension must be at least 1, got " + to_string(shape));
  Tensor s = scalar(v, d);
  return shape.empty() ? s : s.broadcast_to(shape);  // an Expand of a scalar: small in the ONNX file
}
Tensor Session::zeros(const Shape& shape, std::optional<DType> d) { return full_impl(shape, 0, d ? *d : default_float); }
Tensor Session::ones(const Shape& shape, std::optional<DType> d) { return full_impl(shape, 1, d ? *d : default_float); }

Tensor Session::arange(int64_t n, std::optional<DType> d) { return arange_impl(0.0, static_cast<double>(n), 1.0, d ? *d : default_int); }

Tensor Session::arange_impl(double start, double stop, double step, DType d) {
  if (step == 0) throw Error("np: arange with step 0");
  double count = std::ceil((stop - start) / step);
  if (!(count >= 1)) throw Error("np: arange would be empty (tensors need at least one element per dimension)");
  std::vector<double> v;
  for (int64_t k = 0; k < static_cast<int64_t>(count); k++) v.push_back(start + static_cast<double>(k) * step);
  return array(v, d);
}

Tensor Session::linspace(double start, double stop, int64_t num, std::optional<DType> d, bool endpoint) {
  if (num < 1) throw Error("np: linspace needs at least one point");
  std::vector<double> v;
  for (int64_t k = 0; k < num; k++) {
    if (!endpoint) v.push_back(start + static_cast<double>(k) * (stop - start) / static_cast<double>(num));
    else v.push_back(num == 1 ? start : k == num - 1 ? stop : start + static_cast<double>(k) * (stop - start) / static_cast<double>(num - 1));
  }
  return array(v, d);
}

Tensor Session::eye(int64_t n, std::optional<DType> d) {
  if (n < 1) throw Error("np: eye needs n >= 1");
  std::vector<double> v(static_cast<size_t>(n * n), 0.0);
  for (int64_t k = 0; k < n; k++) v[static_cast<size_t>(k * n + k)] = 1;
  return array(v, Shape{n, n}, d);
}

Tensor Session::eye(int64_t rows, int64_t cols, int64_t k, std::optional<DType> d) {
  if (rows < 1 || cols < 1) throw Error("np: eye needs rows and columns of at least 1");
  std::vector<double> v(static_cast<size_t>(rows * cols), 0.0);
  for (int64_t i = 0; i < rows; i++) {
    const int64_t j = i + k;
    if (j >= 0 && j < cols) v[static_cast<size_t>(i * cols + j)] = 1;
  }
  return array(v, Shape{rows, cols}, d);
}

Tensor Session::placeholder(const std::string& name, const Shape& shape, std::optional<DType> d) {
  if (name.compare(0, 4, "_buf") == 0) throw Error("np: placeholder names starting with _buf are reserved");
  return Tensor(this, hir_.add_input(name, d ? *d : default_float, shape));
}

Array Session::eval(const Tensor& t, const std::map<std::string, Array>& feeds) { return eval_all({t}, feeds)[0]; }

std::vector<Array> Session::eval_all(const std::vector<Tensor>& ts, const std::map<std::string, Array>& feeds) {
  if (backend == ut::Session::Backend::Ort || backend == ut::Session::Backend::Tinygrad) {  // the graph itself goes to the library; nothing is lowered
    std::vector<int> ids;
    for (const Tensor& t : ts) {
      check(t);
      if (&t.session() != this) throw Error("np: tensor of another session");
      ids.push_back(t.id());
    }
    if (backend == ut::Session::Backend::Ort) return ort::run(hir_, ids, feeds);
    return tinygrad::run(hir_, ids, feeds);
  }
  std::vector<ut::Tensor> lowered;
  for (const Tensor& t : ts) {
    check(t);
    if (&t.session() != this) throw Error("np: tensor of another session");
    lowered.push_back(lowerer_.get(t.id()));
  }
  ut_.optimize = optimize;
  ut_.backend = backend;
  ut_.cc = cc;
  return ut_.eval_all(lowered, feeds);
}

std::string Session::to_onnx(const std::vector<std::pair<std::string, Tensor>>& outputs, const std::string& graph_name) {
  std::vector<int> ids;
  for (const auto& o : outputs) {
    check(o.second);
    if (&o.second.session() != this) throw Error("np: tensor of another session");
    ids.push_back(hir_.add_node("Identity", {o.second.id()}, {}, o.first));
  }
  return hir_.to_onnx(ids, graph_name);
}

void Session::save_onnx(const std::string& path, const std::vector<std::pair<std::string, Tensor>>& outputs) {
  std::string bytes = to_onnx(outputs);
  std::ofstream f(path, std::ios::binary);
  f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  if (!f) throw Error("np: cannot write " + path);
}

// ---- functions ----

Tensor where(const Tensor& cond, const Tensor& a, const Tensor& b) {
  same_session(a, b);
  check(cond);
  Tensor c = cond.dtype() == DType::Bool ? cond : cast_to(cond, DType::Bool);
  DType dt = promote(a.dtype(), b.dtype());
  return node("Where", {c, cast_to(a, dt), cast_to(b, dt)});
}

Tensor maximum(const Tensor& a, const Tensor& b) { return arith("Max", a, b); }
Tensor minimum(const Tensor& a, const Tensor& b) { return arith("Min", a, b); }

Tensor floor_divide(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = int_dtype(a, b, "floor_divide");
  Tensor x = cast_to(a, dt), y = cast_to(b, dt);
  Tensor q = node("Div", {x, y});
  Tensor r = node("Mod", {x, y}, {Attribute::Int("fmod", 1)});
  return node("Sub", {q, cast_to(floor_adjust(r, y), dt)});
}

Tensor remainder(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = int_dtype(a, b, "remainder");
  return node("Mod", {cast_to(a, dt), cast_to(b, dt)}, {Attribute::Int("fmod", 0)});
}

Tensor logical_not(const Tensor& a) {
  check(a);
  return a.dtype() == DType::Bool ? bool_not(a) : node("Equal", {a, sconst(a, 0)});
}

Tensor concatenate(const std::vector<Tensor>& ts, int64_t axis) {
  if (ts.empty()) throw Error("np: concatenate needs at least one tensor");
  DType dt = ts[0].dtype();
  for (const Tensor& t : ts) {
    same_session(ts[0], t);
    dt = promote(dt, t.dtype());
  }
  axis = norm_axis(axis, ts[0].ndim());
  std::vector<Tensor> parts;
  for (const Tensor& t : ts) parts.push_back(cast_to(t, dt));
  return node("Concat", parts, {Attribute::Int("axis", axis)});
}

Tensor stack(const std::vector<Tensor>& ts, int64_t axis) {
  if (ts.empty()) throw Error("np: stack needs at least one tensor");
  axis = norm_axis(axis, ts[0].ndim() + 1);
  std::vector<Tensor> parts;
  for (const Tensor& t : ts) {
    if (t.shape() != ts[0].shape()) throw Error("np: stack needs tensors of the same shape");
    parts.push_back(t.expand_dims(axis));
  }
  return concatenate(parts, axis);
}

Tensor tile(const Tensor& a, const Shape& reps) {
  check(a);
  for (int64_t r : reps)
    if (r < 1) throw Error("np: tile repetitions must be at least 1, got " + std::to_string(r));
  const size_t n = std::max(reps.size(), static_cast<size_t>(a.ndim()));
  Shape rp(n - reps.size(), 1);
  rp.insert(rp.end(), reps.begin(), reps.end());
  Tensor x = a;
  if (static_cast<size_t>(a.ndim()) < n) {
    Shape s(n - static_cast<size_t>(a.ndim()), 1);
    s.insert(s.end(), a.shape().begin(), a.shape().end());
    x = a.reshape(s);
  }
  return node(x, "Tile", {x.id(), int64_const(x, rp).id()});
}

Tensor take(const Tensor& a, const Tensor& indices, int64_t axis) {
  same_session(a, indices);
  if (!is_int(indices.dtype())) throw Error("np: take needs integer indices, got " + std::string(name(indices.dtype())));
  Tensor src = axis == None ? a.flatten() : a;
  const int64_t ax = axis == None ? 0 : norm_axis(axis, a.ndim());
  if (src.dtype() != DType::Bool) return node(src, "Gather", {src.id(), indices.id()}, {Attribute::Int("axis", ax)});
  // ONNX Gather has no bool data: the values go through the default int and back (exact)
  Tensor data = cast_to(src, a.session().default_int);
  return cast_to(node(data, "Gather", {data.id(), indices.id()}, {Attribute::Int("axis", ax)}), DType::Bool);
}

Tensor pow(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = int_or_default(a, promote(a.dtype(), b.dtype()));
  return node("Pow", {cast_to(a, dt), cast_to(b, dt)});
}

Tensor matmul(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = int_or_default(a, promote(a.dtype(), b.dtype()));
  return node("MatMul", {cast_to(a, dt), cast_to(b, dt)});
}

// ---- the Array API standard (see nfcuop_np.hpp, docs/notes/array-api.md) ----

namespace {

Shape broadcast_shapes(const std::vector<Shape>& ss) {
  size_t nd = 0;
  for (const Shape& s : ss) nd = std::max(nd, s.size());
  Shape out(nd, 1);
  for (const Shape& s : ss) {
    for (size_t k = 0; k < s.size(); k++) {   // aligned on the right
      const int64_t d = s[k];
      int64_t& o = out[nd - s.size() + k];
      if (d == 1) continue;
      if (o == 1) o = d;
      else if (o != d) throw Error("np: shapes " + to_string(ss[0]) + " and others cannot be broadcast together");
    }
  }
  return out;
}

// a Bool constant of `shape`, one entry per element in row-major order
Tensor bool_const(const Tensor& like, const Shape& shape, const std::vector<bool>& v) {
  Array a;
  a.dtype = DType::Bool;
  a.shape = shape;
  for (bool b : v) a.data.push_back(Scalar::from_int(DType::Bool, b ? 1 : 0));
  return Tensor(&like.session(), like.session().constant(a));
}

// the permutation that moves axis `a` to the end (the others keep their order)
Axes last_axis_perm(int64_t nd, int64_t a) {
  Axes perm;
  for (int64_t k = 0; k < nd; k++)
    if (k != a) perm.push_back(k);
  perm.push_back(a);
  return perm;
}

Axes inverse_perm(const Axes& perm) {
  Axes inv(perm.size());
  for (size_t j = 0; j < perm.size(); j++) inv[static_cast<size_t>(perm[j])] = static_cast<int64_t>(j);
  return inv;
}

bool is_identity(const Axes& perm) {
  for (size_t k = 0; k < perm.size(); k++)
    if (perm[k] != static_cast<int64_t>(k)) return false;
  return true;
}

// `v` with one entry along `axis` in front, equal to `value` (the initial element of a cumulative sum or product)
Tensor with_initial(const Tensor& v, int64_t axis, double value) {
  Shape s = v.shape();
  s[static_cast<size_t>(axis)] = 1;
  return concatenate({v.session().full_impl(s, value, v.dtype()), v}, axis);
}

// For the rows of y (..., n), the sort order along the last axis: P[..., i, k] is true when element k comes before element i
// (ascending, or descending). NaN comes last ascending and first descending. Equal elements keep their index order.
Tensor precedes(const Tensor& y, bool descending) {
  const int64_t n = y.shape().back();
  Tensor yi = y.expand_dims(-1);   // (..., n, 1): element i, the row
  Tensor yk = y.expand_dims(-2);   // (..., 1, n): element k, the column
  Tensor before = descending ? (yi < yk) : (yk < yi);
  Tensor same = yk == yi;
  if (is_float(y.dtype())) {
    Tensor ni = yi.isnan(), nk = yk.isnan();
    before = before | (descending ? (nk & bool_not(ni)) : (ni & bool_not(nk)));
    same = same | (ni & nk);
  }
  std::vector<bool> lower;   // [i][k] = k < i
  for (int64_t i = 0; i < n; i++)
    for (int64_t k = 0; k < n; k++) lower.push_back(k < i);
  return before | (same & bool_const(y, {n, n}, lower));
}

// argsort of the last axis of y (..., n): the position of each element in the sort order is its rank (the number of elements
// that come before it); the element of rank j is the one that the sorted array holds at j.
Tensor argsort_last(const Tensor& y, bool descending) {
  Session& s = y.session();
  const int64_t n = y.shape().back();
  Tensor rank = precedes(y, descending).sum(-1);                  // (..., n)
  Tensor hit = rank.expand_dims(-2) == s.arange(n).reshape({n, 1});  // [j][i] = rank of i is j
  Tensor index_row = s.arange(n).reshape({1, n});
  return where(hit, index_row, sconst(index_row, 0)).sum(-1);
}

Tensor sort_or_argsort(const Tensor& x, int64_t axis, bool descending, bool values) {
  check(x);
  const int64_t nd = x.ndim();
  if (nd == 0) throw Error("np: sort needs at least one dimension");
  const int64_t a = norm_axis(axis, nd);
  const Axes perm = last_axis_perm(nd, a);
  Tensor y = a == nd - 1 ? x : x.transpose(perm);
  Tensor idx = argsort_last(y, descending);
  Tensor out = values ? take_along_axis(y, idx, nd - 1) : idx;
  return a == nd - 1 ? out : out.transpose(inverse_perm(perm));
}

// cumulative product along axis `a` (normalized, the tensor not flattened): output i is the product of the first i + 1 elements
Tensor cumprod_axis(const Tensor& x, int64_t a) {
  const int64_t nd = x.ndim();
  const Axes perm = last_axis_perm(nd, a);
  Tensor y = a == nd - 1 ? x : x.transpose(perm);
  const int64_t n = y.shape().back();
  std::vector<bool> keep;   // [i][k] = k <= i
  for (int64_t i = 0; i < n; i++)
    for (int64_t k = 0; k < n; k++) keep.push_back(k <= i);
  Tensor factors = where(bool_const(y, {n, n}, keep), y.expand_dims(-2), sconst(y, 1));
  Tensor out = factors.prod(-1);
  return a == nd - 1 ? out : out.transpose(inverse_perm(perm));
}

Tensor truth(const Tensor& a) {
  check(a);
  return a.dtype() == DType::Bool ? a : a != 0;
}

Tensor require_bool(const Tensor& a, const Tensor& b, const char* what) {
  same_session(a, b);
  if (a.dtype() != DType::Bool || b.dtype() != DType::Bool) throw Error(std::string("np: ") + what + " needs bool operands");
  return a;
}

}  // namespace

// ---- elementwise ----

Tensor operator+(const Tensor& a) { return positive(a); }

Tensor positive(const Tensor& a) {
  check(a);
  if (a.dtype() == DType::Bool) throw Error("np: positive is not defined for bool");
  return a;
}

Tensor operator~(const Tensor& a) {
  check(a);
  if (a.dtype() == DType::Bool) return bool_not(a);
  if (!is_int(a.dtype())) throw Error("np: bitwise_invert needs integers or bool");
  return -a - sconst(a, 1);   // two's complement: ~x == -x - 1
}

Tensor add(const Tensor& a, const Tensor& b) { return a + b; }
Tensor subtract(const Tensor& a, const Tensor& b) { return a - b; }
Tensor multiply(const Tensor& a, const Tensor& b) { return a * b; }
Tensor divide(const Tensor& a, const Tensor& b) { return a / b; }
Tensor negative(const Tensor& a) { return -a; }
Tensor equal(const Tensor& a, const Tensor& b) { return a == b; }
Tensor not_equal(const Tensor& a, const Tensor& b) { return a != b; }
Tensor greater(const Tensor& a, const Tensor& b) { return a > b; }
Tensor greater_equal(const Tensor& a, const Tensor& b) { return a >= b; }
Tensor less(const Tensor& a, const Tensor& b) { return a < b; }
Tensor less_equal(const Tensor& a, const Tensor& b) { return a <= b; }
Tensor logical_and(const Tensor& a, const Tensor& b) { return require_bool(a, b, "logical_and") & b; }
Tensor logical_or(const Tensor& a, const Tensor& b) { return require_bool(a, b, "logical_or") | b; }
Tensor logical_xor(const Tensor& a, const Tensor& b) { return require_bool(a, b, "logical_xor") ^ b; }
Tensor bitwise_and(const Tensor& a, const Tensor& b) { return a & b; }
Tensor bitwise_or(const Tensor& a, const Tensor& b) { return a | b; }
Tensor bitwise_xor(const Tensor& a, const Tensor& b) { return a ^ b; }
Tensor bitwise_invert(const Tensor& a) { return ~a; }

Tensor isfinite(const Tensor& a) {
  check(a);
  if (!is_float(a.dtype())) return a.session().ones(a.shape(), DType::Bool);
  return bool_not(a.isnan() | a.isinf());
}

Tensor trunc(const Tensor& a) {
  check(a);
  if (a.dtype() == DType::Bool) throw Error("np: trunc is not defined for bool");
  if (is_int(a.dtype())) return a;
  return where(a < 0, a.ceil(), a.floor());
}

Tensor sign(const Tensor& a) {
  check(a);
  if (a.dtype() == DType::Bool) throw Error("np: sign is not defined for bool");
  Tensor s = where(a > 0, sconst(a, 1), where(a < 0, sconst(a, -1), sconst(a, 0)));
  return is_float(a.dtype()) ? where(a.isnan(), a, s) : s;
}

// ---- creation ----

Tensor asarray(const Tensor& a, std::optional<DType> d) {
  check(a);
  return d && *d != a.dtype() ? a.astype(*d) : a;
}

Tensor asarray(Session& s, const Array& a, std::optional<DType> d) {
  Tensor t = s.from(a);
  return d ? t.astype(*d) : t;
}

Tensor zeros_like(const Tensor& a, std::optional<DType> d) {
  check(a);
  return a.session().zeros(a.shape(), d ? *d : a.dtype());
}

Tensor ones_like(const Tensor& a, std::optional<DType> d) {
  check(a);
  return a.session().ones(a.shape(), d ? *d : a.dtype());
}

Tensor empty_like(const Tensor& a, std::optional<DType> d) { return zeros_like(a, d); }

Tensor full_like(const Tensor& a, double v, std::optional<DType> d) {
  check(a);
  return a.session().full_impl(a.shape(), v, d ? *d : a.dtype());
}

namespace {
Tensor triangle(const Tensor& a, int64_t k, bool lower) {
  check(a);
  if (a.ndim() < 2) throw Error("np: tril and triu need at least two dimensions");
  const Shape s = a.shape();
  const int64_t r = s[s.size() - 2], c = s.back();
  std::vector<bool> keep;
  for (int64_t i = 0; i < r; i++)
    for (int64_t j = 0; j < c; j++) keep.push_back(lower ? j - i <= k : j - i >= k);
  return where(bool_const(a, {r, c}, keep), a, sconst(a, 0));
}
}  // namespace

Tensor tril(const Tensor& a, int64_t k) { return triangle(a, k, true); }
Tensor triu(const Tensor& a, int64_t k) { return triangle(a, k, false); }

std::vector<Tensor> meshgrid(const std::vector<Tensor>& xs, bool xy) {
  if (xs.empty()) throw Error("np: meshgrid needs at least one array");
  const size_t n = xs.size();
  Shape out(n);
  for (size_t i = 0; i < n; i++) {
    if (xs[i].ndim() != 1) throw Error("np: meshgrid needs one-dimensional arrays");
    out[i] = xs[i].shape()[0];
  }
  const bool swap = xy && n >= 2;   // "xy": the first two inputs vary along the second and first axes
  if (swap) std::swap(out[0], out[1]);
  std::vector<Tensor> res;
  for (size_t i = 0; i < n; i++) {
    size_t pos = i;
    if (swap && i < 2) pos = 1 - i;
    Shape s(n, 1);
    s[pos] = xs[i].shape()[0];
    res.push_back(xs[i].reshape(s).broadcast_to(out));
  }
  return res;
}

Tensor copy(const Tensor& a) {
  check(a);
  return a;
}

// ---- data types ----

DType result_type(DType a, DType b) { return promote(a, b); }

DType result_type(const std::vector<Tensor>& ts) {
  if (ts.empty()) throw Error("np: result_type needs at least one tensor");
  DType d = ts[0].dtype();
  for (const Tensor& t : ts) d = promote(d, t.dtype());
  return d;
}

bool can_cast(DType from, DType to) {
  if (from == to || from == DType::Bool) return true;
  switch (from) {
    case DType::Int32: return to == DType::Int64 || to == DType::Float64;
    case DType::Int64: return to == DType::Float64;
    case DType::Float32: return to == DType::Float64;
    default: return false;
  }
}

FInfo finfo(DType d) {
  switch (d) {
    case DType::Float32: return {d, 32, FLT_EPSILON, FLT_MAX, -FLT_MAX, FLT_MIN};
    case DType::Float64: return {d, 64, DBL_EPSILON, DBL_MAX, -DBL_MAX, DBL_MIN};
    default: throw Error(std::string("np: finfo needs a floating dtype, got ") + name(d));
  }
}

IInfo iinfo(DType d) {
  switch (d) {
    case DType::Int32: return {d, 32, INT32_MIN, INT32_MAX};
    case DType::Int64: return {d, 64, INT64_MIN, INT64_MAX};
    default: throw Error(std::string("np: iinfo needs an integer dtype, got ") + name(d));
  }
}

bool isdtype(DType d, const std::string& kind) {
  const bool sint = d == DType::Int32 || d == DType::Int64;
  const bool rfloat = d == DType::Float32 || d == DType::Float64;
  if (kind == "bool") return d == DType::Bool;
  if (kind == "signed integer" || kind == "integral") return sint;
  if (kind == "real floating") return rfloat;
  if (kind == "numeric") return sint || rfloat;
  if (kind == "unsigned integer" || kind == "complex floating") return false;
  throw Error("np: isdtype: unknown kind \"" + kind + "\"");
}

bool isdtype(DType d, const std::vector<std::string>& kinds) {
  for (const std::string& k : kinds)
    if (isdtype(d, k)) return true;
  return false;
}

std::vector<Tensor> broadcast_arrays(const std::vector<Tensor>& ts) {
  if (ts.empty()) throw Error("np: broadcast_arrays needs at least one tensor");
  std::vector<Shape> ss;
  for (const Tensor& t : ts) {
    check(t);
    ss.push_back(t.shape());
  }
  const Shape out = broadcast_shapes(ss);
  std::vector<Tensor> res;
  for (const Tensor& t : ts) res.push_back(t.shape() == out ? t : t.broadcast_to(out));
  return res;
}

// ---- searching, sorting ----

Tensor searchsorted(const Tensor& sorted, const Tensor& v, bool right) {
  same_session(sorted, v);
  if (sorted.ndim() != 1) throw Error("np: searchsorted needs a one-dimensional sorted array");
  Tensor col = v.expand_dims(-1);                       // (..., 1) against the n sorted values
  Tensor hit = right ? sorted <= col : sorted < col;    // (..., n): sorted[k] before the value
  if (is_float(promote(sorted.dtype(), v.dtype()))) {  // NaN sorts last: before a NaN come the non-NaN values
    Tensor nv = col.isnan(), ns = sorted.isnan();
    hit = right ? hit | nv : hit | (nv & bool_not(ns));
  }
  return hit.sum(-1);   // the number of values before, the default int (sorted must be sorted: otherwise numpy's binary search differs)
}

Tensor count_nonzero(const Tensor& a, const Axes& axes, bool keepdims) {
  check(a);
  return (a != 0).sum(axes, keepdims);
}

Tensor sort(const Tensor& a, int64_t axis, bool descending) { return sort_or_argsort(a, axis, descending, true); }
Tensor argsort(const Tensor& a, int64_t axis, bool descending) { return sort_or_argsort(a, axis, descending, false); }

Tensor take_along_axis(const Tensor& x, const Tensor& indices, int64_t axis) {
  same_session(x, indices);
  if (!is_int(indices.dtype())) throw Error("np: take_along_axis needs integer indices, got " + std::string(name(indices.dtype())));
  const int64_t nd = x.ndim();
  if (indices.ndim() != nd) throw Error("np: take_along_axis needs indices of the same rank as the array");
  const int64_t a = norm_axis(axis, nd);
  const Shape xs = x.shape(), is = indices.shape();
  Shape out(static_cast<size_t>(nd));
  for (int64_t k = 0; k < nd; k++) {
    const size_t u = static_cast<size_t>(k);
    if (k == a) out[u] = is[u];
    else if (is[u] == 1 || xs[u] == is[u]) out[u] = xs[u];
    else if (xs[u] == 1) out[u] = is[u];
    else throw Error("np: take_along_axis: shapes " + to_string(xs) + " and " + to_string(is) + " do not broadcast along axis " + std::to_string(k));
  }
  // the flat position in x of each element: the index along the axis times its stride, plus the position along the other axes
  const int64_t n = xs[static_cast<size_t>(a)];
  Tensor idx = where(indices < 0, indices + n, indices);   // negative indices count from the end, as in numpy
  std::vector<int64_t> st(static_cast<size_t>(nd));
  int64_t stride = 1;
  for (int64_t k = nd - 1; k >= 0; k--) {
    st[static_cast<size_t>(k)] = stride;
    stride *= xs[static_cast<size_t>(k)];
  }
  Tensor offset = idx.broadcast_to(out) * st[static_cast<size_t>(a)];
  for (int64_t k = 0; k < nd; k++) {
    const size_t u = static_cast<size_t>(k);
    if (k == a || xs[u] == 1 || out[u] == 1) continue;   // a broadcast axis of x contributes position 0
    Shape s(static_cast<size_t>(nd), 1);
    s[u] = out[u];
    offset = offset + x.session().arange(out[u], indices.dtype()).reshape(s) * st[u];
  }
  return take(x.reshape({x.size()}), offset);
}

// ---- statistics, utility ----

Tensor cumulative_sum(const Tensor& a, int64_t axis, bool include_initial) {
  check(a);
  Tensor c = a.cumsum(axis);
  if (!include_initial) return c;
  return with_initial(c, axis == None ? 0 : norm_axis(axis, a.ndim()), 0);
}

Tensor cumulative_prod(const Tensor& a, int64_t axis, bool include_initial) {
  check(a);
  Tensor x = axis == None ? a.flatten() : a;
  const int64_t ax = axis == None ? 0 : norm_axis(axis, a.ndim());
  DType dt = x.dtype();
  if (dt == DType::Bool || (is_int(dt) && dt < a.session().default_int)) dt = a.session().default_int;
  Tensor p = cumprod_axis(cast_to(x, dt), ax);
  return include_initial ? with_initial(p, ax, 1) : p;
}

Tensor cumprod(const Tensor& a, int64_t axis) { return cumulative_prod(a, axis, false); }

Tensor all(const Tensor& a, const Axes& axes, bool keepdims) { return truth(a).min(axes, keepdims); }
Tensor any(const Tensor& a, const Axes& axes, bool keepdims) { return truth(a).max(axes, keepdims); }

// ---- manipulation ----

Tensor concat(const std::vector<Tensor>& ts, int64_t axis) { return concatenate(ts, axis); }

Tensor moveaxis(const Tensor& a, int64_t source, int64_t destination) {
  check(a);
  const int64_t nd = a.ndim();
  const int64_t s = norm_axis(source, nd), d = norm_axis(destination, nd);
  Axes order;
  for (int64_t k = 0; k < nd; k++)
    if (k != s) order.push_back(k);
  order.insert(order.begin() + d, s);
  return a.transpose(order);
}

Tensor permute_dims(const Tensor& a, const Axes& perm) {
  check(a);
  return a.transpose(perm);
}

Tensor repeat(const Tensor& a0, int64_t r, int64_t axis) {
  check(a0);
  if (r < 1) throw Error("np: repeat needs a count of at least 1, got " + std::to_string(r));
  Tensor a = axis == None ? a0.flatten() : a0;
  const int64_t ax = axis == None ? 0 : norm_axis(axis, a.ndim());
  const Shape s = a.shape();
  Shape wide = s;   // the new axis of size r right after axis ax, which holds the copies
  wide.insert(wide.begin() + ax + 1, r);
  Shape out = s;
  out[static_cast<size_t>(ax)] *= r;
  return a.expand_dims(ax + 1).broadcast_to(wide).reshape(out);
}

Tensor roll(const Tensor& a0, int64_t shift, int64_t axis) {
  check(a0);
  if (axis == None) return roll(a0.flatten(), shift, 0).reshape(a0.shape());
  const int64_t ax = norm_axis(axis, a0.ndim());
  const int64_t n = a0.shape()[static_cast<size_t>(ax)];
  const int64_t k = ((shift % n) + n) % n;
  if (k == 0) return a0;
  return concatenate({a0.slice(ax, n - k, n), a0.slice(ax, 0, n - k)}, ax);
}

Tensor roll(const Tensor& a, const Axes& shifts, const Axes& axes) {
  if (shifts.size() != axes.size()) throw Error("np: roll needs as many shifts as axes");
  Tensor x = a;
  for (size_t k = 0; k < shifts.size(); k++) x = roll(x, shifts[k], axes[k]);
  return x;
}

std::vector<Tensor> unstack(const Tensor& a, int64_t axis) {
  check(a);
  const int64_t ax = norm_axis(axis, a.ndim());
  std::vector<Tensor> out;
  for (int64_t i = 0; i < a.shape()[static_cast<size_t>(ax)]; i++) out.push_back(a.at(i, ax));
  return out;
}

// ---- linear algebra ----

Tensor matrix_transpose(const Tensor& a) {
  check(a);
  if (a.ndim() < 2) throw Error("np: matrix_transpose needs at least two dimensions");
  return a.swapaxes(-2, -1);
}

Tensor vecdot(const Tensor& a, const Tensor& b, int64_t axis) {
  same_session(a, b);
  if (a.dtype() == DType::Bool || b.dtype() == DType::Bool) throw Error("np: vecdot is not defined for bool");
  return (a * b).sum(axis);
}

Tensor einsum(const std::string& subscripts, const std::vector<Tensor>& ops) {
  if (ops.empty()) throw Error("np: einsum needs at least one operand");
  std::string spec;
  for (char c : subscripts)
    if (c != ' ') spec += c;
  if (spec.find("...") != std::string::npos) throw Error("np: einsum: ellipsis is not supported");
  const size_t arrow = spec.find("->");
  const bool explicit_out = arrow != std::string::npos;
  if (explicit_out && spec.find("->", arrow + 2) != std::string::npos) throw Error("np: einsum: more than one '->'");
  const std::string lhs = explicit_out ? spec.substr(0, arrow) : spec;
  std::vector<std::string> terms(1);
  for (char c : lhs) {
    if (c == ',') terms.emplace_back();
    else terms.back() += c;
  }
  if (terms.size() != ops.size())
    throw Error("np: einsum: " + std::to_string(terms.size()) + " operand subscripts for " + std::to_string(ops.size()) + " operands");
  auto is_letter = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); };
  std::string all_idx;                 // every index once, in order of first appearance
  std::map<char, int> count;           // in how many operands each index occurs
  for (size_t k = 0; k < ops.size(); k++) {
    const std::string& t = terms[k];
    check(ops[k]);
    if (static_cast<int64_t>(t.size()) != ops[k].ndim())
      throw Error("np: einsum: operand " + std::to_string(k) + " has " + std::to_string(ops[k].ndim()) + " dimensions, its subscripts \"" + t + "\" have " + std::to_string(t.size()));
    for (size_t p = 0; p < t.size(); p++) {
      const char c = t[p];
      if (!is_letter(c)) throw Error(std::string("np: einsum: bad index '") + c + "'");
      if (t.find(c) != p) throw Error("np: einsum: index '" + std::string(1, c) + "' repeated in one operand (a diagonal) is not supported");
      if (count[c]++ == 0) all_idx += c;
    }
  }
  std::string out;
  if (explicit_out) {
    out = spec.substr(arrow + 2);
    for (size_t p = 0; p < out.size(); p++) {
      const char c = out[p];
      if (!is_letter(c) || all_idx.find(c) == std::string::npos) throw Error(std::string("np: einsum: output index '") + c + "' is not an input index");
      if (out.find(c) != p) throw Error(std::string("np: einsum: output index '") + c + "' repeated");
    }
  } else {
    for (char c : all_idx)
      if (count[c] == 1) out += c;
    std::sort(out.begin(), out.end());
  }
  std::map<char, int64_t> size;
  for (size_t k = 0; k < ops.size(); k++)
    for (size_t p = 0; p < terms[k].size(); p++) {
      const char c = terms[k][p];
      const int64_t d = ops[k].shape()[p];
      auto it = size.find(c);
      if (it == size.end()) size[c] = d;
      else if (it->second != d) throw Error("np: einsum: index '" + std::string(1, c) + "' has sizes " + std::to_string(it->second) + " and " + std::to_string(d));
    }
  // each operand as a tensor with every index of all_idx in its place (size 1 where it has no such index), then their product
  Tensor prod;
  for (size_t k = 0; k < ops.size(); k++) {
    const std::string& t = terms[k];
    Axes perm;
    for (char c : all_idx) {
      const size_t p = t.find(c);
      if (p != std::string::npos) perm.push_back(static_cast<int64_t>(p));
    }
    Tensor x = is_identity(perm) ? ops[k] : ops[k].transpose(perm);
    Shape aligned(all_idx.size(), 1);
    for (size_t p = 0; p < all_idx.size(); p++)
      if (t.find(all_idx[p]) != std::string::npos) aligned[p] = size[all_idx[p]];
    x = x.reshape(aligned);
    prod = k == 0 ? x : prod * x;
  }
  Axes summed;
  std::string kept;
  for (size_t p = 0; p < all_idx.size(); p++) {
    if (out.find(all_idx[p]) == std::string::npos) summed.push_back(static_cast<int64_t>(p));
    else kept += all_idx[p];
  }
  if (!summed.empty()) prod = prod.sum(summed);
  if (kept != out) {   // the remaining indices are in the order of all_idx; the output asks for its own order
    Axes pm;
    for (char c : out) pm.push_back(static_cast<int64_t>(kept.find(c)));
    prod = prod.transpose(pm);
  }
  return prod;
}

Tensor tensordot(const Tensor& a, const Tensor& b, const Axes& axes_a, const Axes& axes_b) {
  same_session(a, b);
  if (axes_a.size() != axes_b.size()) throw Error("np: tensordot needs as many axes of each operand");
  const int64_t na = a.ndim(), nb = b.ndim();
  static const std::string pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  std::string la(static_cast<size_t>(na), ' '), lb(static_cast<size_t>(nb), ' ');
  size_t next = 0;
  auto fresh = [&]() {
    if (next >= pool.size()) throw Error("np: tensordot: too many axes");
    return pool[next++];
  };
  for (int64_t k = 0; k < na; k++) la[static_cast<size_t>(k)] = fresh();
  std::vector<bool> paired(static_cast<size_t>(nb), false);
  for (size_t p = 0; p < axes_a.size(); p++) {
    const int64_t ka = norm_axis(axes_a[p], na), kb = norm_axis(axes_b[p], nb);
    lb[static_cast<size_t>(kb)] = la[static_cast<size_t>(ka)];   // the contracted index of b is the one of a
    paired[static_cast<size_t>(kb)] = true;
  }
  for (int64_t k = 0; k < nb; k++)
    if (!paired[static_cast<size_t>(k)]) lb[static_cast<size_t>(k)] = fresh();
  std::string out;
  for (int64_t k = 0; k < na; k++) {
    bool contracted = false;
    for (size_t p = 0; p < axes_a.size(); p++) contracted = contracted || norm_axis(axes_a[p], na) == k;
    if (!contracted) out += la[static_cast<size_t>(k)];
  }
  for (int64_t k = 0; k < nb; k++)
    if (!paired[static_cast<size_t>(k)]) out += lb[static_cast<size_t>(k)];
  return einsum(la + "," + lb + "->" + out, {a, b});
}

Tensor tensordot(const Tensor& a, const Tensor& b, int64_t n) {
  if (n < 0 || n > a.ndim() || n > b.ndim()) throw Error("np: tensordot: " + std::to_string(n) + " axes do not exist in both operands");
  Axes xa, xb;
  for (int64_t k = 0; k < n; k++) {
    xa.push_back(a.ndim() - n + k);
    xb.push_back(k);
  }
  return tensordot(a, b, xa, xb);
}

std::vector<Tensor> grad(const Tensor& loss, const std::vector<Tensor>& wrt) {
  check(loss);
  std::vector<int> ids;
  for (const Tensor& w : wrt) {
    same_session(loss, w);
    ids.push_back(w.id());
  }
  std::vector<Tensor> out;
  for (int id : hir::gradients_via_onnxsim(H(loss), loss.id(), ids)) out.push_back(Tensor(&loss.session(), id));
  return out;
}

Tensor grad(const Tensor& loss, const Tensor& wrt) { return grad(loss, std::vector<Tensor>{wrt})[0]; }

Tensor operator+(const Tensor& a, const Tensor& b) { return arith("Add", a, b); }
Tensor operator-(const Tensor& a, const Tensor& b) { return arith("Sub", a, b); }
Tensor operator*(const Tensor& a, const Tensor& b) { return arith("Mul", a, b); }
Tensor operator/(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = promote(a.dtype(), b.dtype());
  if (!is_float(dt)) dt = a.session().default_float;
  return node("Div", {cast_to(a, dt), cast_to(b, dt)});
}
Tensor operator%(const Tensor& a, const Tensor& b) { return remainder(a, b); }
Tensor operator<(const Tensor& a, const Tensor& b) { return compare("Less", a, b); }
Tensor operator>(const Tensor& a, const Tensor& b) { return compare("Greater", a, b); }
Tensor operator<=(const Tensor& a, const Tensor& b) { return compare("LessOrEqual", a, b); }
Tensor operator>=(const Tensor& a, const Tensor& b) { return compare("GreaterOrEqual", a, b); }
Tensor operator==(const Tensor& a, const Tensor& b) { return compare("Equal", a, b); }
Tensor operator!=(const Tensor& a, const Tensor& b) { return bool_not(compare("Equal", a, b)); }
Tensor operator&(const Tensor& a, const Tensor& b) { return logic("And", "BitwiseAnd", a, b); }
Tensor operator|(const Tensor& a, const Tensor& b) { return logic("Or", "BitwiseOr", a, b); }
Tensor operator^(const Tensor& a, const Tensor& b) { return logic("Xor", "BitwiseXor", a, b); }

}  // namespace np
}  // namespace nfcuop
