// nfcuop::np: the numpy-like API over the ONNX-style graph. See nfcuop_np.hpp.
#include "nfcuop_np.hpp"

#include "nfcuop_onnxgrad.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>

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

Tensor Tensor::var(const Axes& axes, bool keepdims) const {
  check(*this);
  Tensor x = to_float(*this);
  Tensor d = x - x.mean(axes, true);
  return (d * d).mean(axes, keepdims);
}

Tensor Tensor::stddev(const Axes& axes, bool keepdims) const { return var(axes, keepdims).sqrt(); }

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

Tensor Tensor::floor() const { Tensor x = to_float(*this); return node(x, "Floor", {x.id()}); }
Tensor Tensor::ceil() const { Tensor x = to_float(*this); return node(x, "Ceil", {x.id()}); }

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

Tensor Session::linspace(double start, double stop, int64_t num, std::optional<DType> d) {
  if (num < 1) throw Error("np: linspace needs at least one point");
  std::vector<double> v;
  for (int64_t k = 0; k < num; k++)
    v.push_back(num == 1 ? start : k == num - 1 ? stop : start + static_cast<double>(k) * (stop - start) / static_cast<double>(num - 1));
  return array(v, d);
}

Tensor Session::eye(int64_t n, std::optional<DType> d) {
  if (n < 1) throw Error("np: eye needs n >= 1");
  std::vector<double> v(static_cast<size_t>(n * n), 0.0);
  for (int64_t k = 0; k < n; k++) v[static_cast<size_t>(k * n + k)] = 1;
  return array(v, Shape{n, n}, d);
}

Tensor Session::placeholder(const std::string& name, const Shape& shape, std::optional<DType> d) {
  if (name.compare(0, 4, "_buf") == 0) throw Error("np: placeholder names starting with _buf are reserved");
  return Tensor(this, hir_.add_input(name, d ? *d : default_float, shape));
}

Array Session::eval(const Tensor& t, const std::map<std::string, Array>& feeds) { return eval_all({t}, feeds)[0]; }

std::vector<Array> Session::eval_all(const std::vector<Tensor>& ts, const std::map<std::string, Array>& feeds) {
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
