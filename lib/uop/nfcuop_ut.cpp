// nfcuop::ut: the numpy-like Tensor API. See nfcuop_ut.hpp.
#include "nfcuop_ut.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>

namespace nfcuop {
namespace ut {

namespace {

const double kLog2E = 1.4426950408889634074;
const double kLn2 = 0.69314718055994530942;
const double kPi = 3.14159265358979323846;

Graph& G(const Tensor& t) { return t.session().graph(); }
Tensor wrap(const Tensor& like, const UOp* u) { return Tensor(&like.session(), u); }
void check(const Tensor& t) {
  if (!t.valid()) throw Error("np: use of an empty Tensor");
}
void same_session(const Tensor& a, const Tensor& b) {
  check(a);
  check(b);
  if (&a.session() != &b.session()) throw Error("np: tensors of different sessions");
}

DType promote(DType a, DType b) { return a > b ? a : b; }  // the enum is ordered bool < int32 < int64 < float32 < float64

Tensor cast_to(const Tensor& t, DType d) { return t.dtype() == d ? t : wrap(t, G(t).cast(t.uop(), d)); }
Tensor to_float(const Tensor& t) { return is_float(t.dtype()) ? t : cast_to(t, DType::Float32); }

// A constant tensor of t's shape and dtype (floats and ints; v is converted).
const UOp* cst(const Tensor& like, double v) { return G(like).constant(Scalar::from_double(like.dtype(), v), like.shape()); }
Tensor cst_t(const Tensor& like, double v) { return wrap(like, cst(like, v)); }

int64_t norm_axis(int64_t ax, int64_t nd) {
  if (ax < -nd || ax >= nd) throw Error("np: axis " + std::to_string(ax) + " is out of range for " + std::to_string(nd) + " dimensions");
  return ax < 0 ? ax + nd : ax;
}

Shape broadcast_shape(const Shape& a, const Shape& b) {
  size_t n = std::max(a.size(), b.size());
  Shape out(n);
  for (size_t k = 0; k < n; k++) {
    int64_t da = k < n - a.size() ? 1 : a[k - (n - a.size())];
    int64_t db = k < n - b.size() ? 1 : b[k - (n - b.size())];
    if (da != db && da != 1 && db != 1)
      throw Error("np: shapes " + to_string(a) + " and " + to_string(b) + " cannot be broadcast together");
    out[k] = da == 1 ? db : da;
  }
  return out;
}

Tensor bcast(const Tensor& t, const Shape& out) {
  if (t.shape() == out) return t;
  Shape padded(out.size() - t.shape().size(), 1);
  padded.insert(padded.end(), t.shape().begin(), t.shape().end());
  const UOp* u = t.uop();
  if (padded != t.shape()) u = G(t).reshape(u, padded);
  if (padded != out) u = G(t).expand(u, out);
  return wrap(t, u);
}

// Both operands cast to `dt` and broadcast to one shape.
void prepare(Tensor& a, Tensor& b, DType dt) {
  same_session(a, b);
  Shape out = broadcast_shape(a.shape(), b.shape());
  a = bcast(cast_to(a, dt), out);
  b = bcast(cast_to(b, dt), out);
}

Tensor arith(Op op, Tensor a, Tensor b) {  // Add Sub Mul Max: bool operands become int32
  DType dt = promote(a.dtype(), b.dtype());
  if (dt == DType::Bool) dt = DType::Int32;
  prepare(a, b, dt);
  return wrap(a, G(a).alu(op, {a.uop(), b.uop()}));
}

Tensor logic(Op op, Tensor a, Tensor b) {  // And Or Xor
  prepare(a, b, promote(a.dtype(), b.dtype()));
  return wrap(a, G(a).alu(op, {a.uop(), b.uop()}));
}

Tensor compare(Op op, Tensor a, Tensor b) {  // CmpLt CmpNe
  prepare(a, b, promote(a.dtype(), b.dtype()));
  return wrap(a, G(a).alu(op, {a.uop(), b.uop()}));
}

Tensor bool_not(const Tensor& x) {  // x is Bool
  return wrap(x, G(x).alu(Op::Xor, {x.uop(), G(x).iconst(DType::Bool, 1, x.shape())}));
}

Tensor int_only(const Tensor& a, const Tensor& b, const char* what, DType& dt) {
  dt = promote(a.dtype(), b.dtype());
  if (dt == DType::Bool) dt = DType::Int32;
  if (!is_int(dt)) throw Error(std::string("np: ") + what + " is defined for integers only");
  return a;
}

// numpy's floor semantics from C's truncation: adjust when the remainder is nonzero and its sign differs from b's.
Tensor floor_adjust(const Tensor& r, const Tensor& b) {
  Tensor nonzero = compare(Op::CmpNe, r, cst_t(r, 0));
  Tensor signs_differ = compare(Op::CmpNe, compare(Op::CmpLt, r, cst_t(r, 0)), compare(Op::CmpLt, b, cst_t(b, 0)));
  return logic(Op::And, nonzero, signs_differ);
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

Tensor drop_axes(const Tensor& t, const Axes& axes) {  // t has those axes with size 1
  Shape s;
  for (int64_t k = 0; k < t.ndim(); k++)
    if (!std::binary_search(axes.begin(), axes.end(), k)) s.push_back(t.shape()[k]);
  return wrap(t, G(t).reshape(t.uop(), s));
}

Tensor reduce(const Tensor& x, Op op, const Axes& axes_in, bool keepdims) {
  check(x);
  Axes axes = norm_axes(axes_in, x.ndim());
  const UOp* u = op == Op::ReduceSum ? G(x).reduce_sum(x.uop(), axes) : G(x).reduce_max(x.uop(), axes);
  Tensor r = wrap(x, u);
  return keepdims ? r : drop_axes(r, axes);
}

// floor (up = false) or ceil of a float tensor: from its truncation t, which is exact below 2^52 (the larger values, infinities and
// NaN are integers or not numbers, and are kept). Signed zeros: ceil of a value in (-1, 0) is -0.0, and floor and ceil keep x = +-0.
Tensor integral(const Tensor& x, bool up) {
  Tensor t = x.astype(DType::Int64).astype(x.dtype());
  Tensor y = up ? where(t < x, t + 1.0, t) : where(t > x, t - 1.0, t);
  if (up) y = where((y == 0.0) & (x < 0.0), cst_t(y, -0.0), y);
  Tensor small = x.abs() < 4503599627370496.0;   // 2^52
  return where(x == 0.0, x, where(small, y, x));
}

// a ** b for ints of one dtype, by squaring over the bits of b (the exponent's bits are read by floor division)
Tensor int_pow(const Tensor& x, const Tensor& y) {
  const int bits = x.dtype() == DType::Int32 ? 31 : 63;   // the bits of a non-negative exponent of that dtype
  Tensor result = cst_t(x, 1), base = x, e = y;
  for (int k = 0; k < bits; k++) {
    Tensor bit = (e % 2) != 0;
    result = where(bit, result * base, result);
    base = base * base;
    e = trunc_divide(e, detail::lift(e, 2, true));
  }
  Tensor odd = (y % 2) != 0;
  Tensor neg_value = where(x == 1, cst_t(x, 1), where(x == -1, where(odd, cst_t(x, -1), cst_t(x, 1)), cst_t(x, 0)));
  return where(y < 0, neg_value, result);
}

// argmax (want_max) or argmin along `axis`: the first index of the extreme value, or the last one (`last`); a NaN wins
Tensor arg_select(const Tensor& x, int64_t axis, bool keepdims, bool want_max, bool last) {
  check(x);
  axis = norm_axis(axis, x.ndim());
  const int64_t S = x.shape()[static_cast<size_t>(axis)];
  Shape vshape(static_cast<size_t>(x.ndim()), 1);
  vshape[static_cast<size_t>(axis)] = S;
  Tensor idx = x.session().arange(S, DType::Int64).reshape(vshape);
  const int64_t none = last ? -1 : S;   // the index that no element has
  Tensor m = want_max ? x.max(Axes{axis}, true) : x.min(Axes{axis}, true);
  Tensor cand = where(x == m, idx, cst_t(idx, static_cast<double>(none)));
  Tensor r = last ? cand.max(Axes{axis}, true) : cand.min(Axes{axis}, true);
  if (is_float(x.dtype())) {   // numpy: the first NaN (the last with `last`) wins over every other element
    Tensor nan = x != x;
    Tensor nc = where(nan, idx, cst_t(idx, static_cast<double>(none)));
    Tensor nr = last ? nc.max(Axes{axis}, true) : nc.min(Axes{axis}, true);
    r = where(nr != cst_t(nr, static_cast<double>(none)), nr, r);
  }
  return keepdims ? r : drop_axes(r, Axes{axis});
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
    if (k) out += dim + 1 == a.shape.size() ? ", " : ", ";
    print(a, dim + 1, pos, out);
  }
  out += "]";
}

}  // namespace

Tensor atan2(const Tensor& y, const Tensor& x) {
  DType dt = promote(y.dtype(), x.dtype());
  if (!is_float(dt)) dt = DType::Float32;
  Tensor a = y, b = x;
  prepare(a, b, dt);
  return wrap(a, G(a).atan2(a.uop(), b.uop()));
}

Tensor shift_left(const Tensor& x, const Tensor& n) {   // Graph::shl checks the dtype (integers only)
  Tensor a = x, b = n;
  prepare(a, b, promote(x.dtype(), n.dtype()));
  return wrap(a, G(a).shl(a.uop(), b.uop()));
}

Tensor shift_right(const Tensor& x, const Tensor& n) {
  Tensor a = x, b = n;
  prepare(a, b, promote(x.dtype(), n.dtype()));
  return wrap(a, G(a).shr(a.uop(), b.uop()));
}

namespace detail {
Tensor lift(const Tensor& like, double v, bool integral) {
  check(like);
  DType dt = integral ? DType::Int32 : (like.dtype() == DType::Float64 ? DType::Float64 : DType::Float32);
  return Tensor(&like.session(), like.session().graph().constant(Scalar::from_double(dt, v)));
}
}  // namespace detail

// ---- Tensor: shape ----

Tensor Tensor::reshape(Shape shape) const {
  check(*this);
  int64_t known = 1, unknown = -1;
  for (size_t k = 0; k < shape.size(); k++) {
    if (shape[k] == -1) {
      if (unknown >= 0) throw Error("np: can only specify one unknown dimension");
      unknown = static_cast<int64_t>(k);
    } else {
      if (shape[k] < 1) throw Error("np: bad dimension in reshape to " + to_string(shape));
      known *= shape[k];
    }
  }
  if (unknown >= 0) {
    if (size() % known) throw Error("np: cannot reshape " + to_string(this->shape()) + " into " + to_string(shape));
    shape[unknown] = size() / known;
  }
  return wrap(*this, G(*this).reshape(u_, shape));
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
  return wrap(*this, G(*this).permute(u_, p));
}

Tensor Tensor::swapaxes(int64_t a, int64_t b) const {
  check(*this);
  Axes p = all_axes(ndim());
  std::swap(p[norm_axis(a, ndim())], p[norm_axis(b, ndim())]);
  return wrap(*this, G(*this).permute(u_, p));
}

Tensor Tensor::slice(int64_t axis, bool has_start, int64_t start, bool has_stop, int64_t stop, int64_t step) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  const int64_t dim = shape()[axis];
  SliceIdx ix = slice_indices(dim, has_start, start, has_stop, stop, step);
  if (ix.count < 1) throw Error("np: the slice of axis " + std::to_string(axis) + " is empty (tensors need at least one element per dimension)");
  const int64_t mag = ix.step < 0 ? -ix.step : ix.step;
  // the ascending run of the selected elements: low, low+mag, ..., high
  const int64_t last = ix.start + (ix.count - 1) * ix.step;
  const int64_t low = ix.step < 0 ? last : ix.start;
  Graph& g = G(*this);
  Shape starts(ndim(), 0), ends = shape();
  starts[axis] = low;
  ends[axis] = low + (ix.count - 1) * mag + 1;
  const UOp* u = g.shrink(u_, starts, ends);
  if (mag > 1) {  // pad the run to a multiple of mag, view it as (count, mag) and keep column 0
    Shape before(ndim(), 0), after(ndim(), 0);
    after[axis] = ix.count * mag - (ends[axis] - starts[axis]);
    u = g.pad(u, before, after);
    Shape split = shape();
    split[axis] = ix.count;
    split.insert(split.begin() + axis + 1, mag);
    u = g.reshape(u, split);
    Shape s0(split.size(), 0), e0 = split;
    e0[axis + 1] = 1;
    u = g.shrink(u, s0, e0);
    Shape out = shape();
    out[axis] = ix.count;
    u = g.reshape(u, out);
  }
  if (ix.step < 0) u = g.flip(u, {axis});
  return wrap(*this, u);
}

Tensor Tensor::flip(const Axes& axes) const {
  check(*this);
  Axes a;
  for (int64_t x : axes) a.push_back(norm_axis(x, ndim()));
  return wrap(*this, G(*this).flip(u_, a));
}

Tensor Tensor::pad(const Shape& before, const Shape& after) const {
  check(*this);
  if (static_cast<int64_t>(before.size()) != ndim() || static_cast<int64_t>(after.size()) != ndim()) throw Error("np: pad needs one amount per axis on each side");
  for (size_t k = 0; k < before.size(); k++) if (before[k] < 0 || after[k] < 0) throw Error("np: pad amounts must not be negative");
  return wrap(*this, G(*this).pad(u_, before, after));
}

Tensor Tensor::pad(const Shape& before, const Shape& after, const Scalar& value) const {
  Tensor p = pad(before, after);
  if (value.dtype != dtype()) throw Error("np: pad value has dtype " + std::string(name(value.dtype)) + ", the tensor " + name(dtype()));
  if (value == Scalar::from_int(dtype(), 0)) return p;  // bitwise: -0.0 is not zero here
  // a padded Bool mask (false in the new places) picks the tensor over the value
  Graph& g = G(*this);
  const UOp* mask = g.pad(g.iconst(DType::Bool, 1, shape()), before, after);
  return wrap(*this, g.where(mask, p.uop(), g.constant(value, p.shape())));
}

Tensor Tensor::squeeze() const {
  check(*this);
  Shape s;
  for (int64_t d : shape()) if (d != 1) s.push_back(d);
  return wrap(*this, G(*this).reshape(u_, s));
}

Tensor Tensor::squeeze(int64_t axis) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  if (shape()[axis] != 1) throw Error("np: cannot squeeze axis " + std::to_string(axis) + " of shape " + to_string(shape()));
  Shape s = shape();
  s.erase(s.begin() + axis);
  return wrap(*this, G(*this).reshape(u_, s));
}

Tensor Tensor::expand_dims(int64_t axis) const {
  check(*this);
  axis = norm_axis(axis, ndim() + 1);
  Shape s = shape();
  s.insert(s.begin() + axis, 1);
  return wrap(*this, G(*this).reshape(u_, s));
}

Tensor Tensor::broadcast_to(const Shape& shape_) const {
  check(*this);
  if (shape_.size() < shape().size()) throw Error("np: cannot broadcast " + to_string(shape()) + " to " + to_string(shape_));
  return bcast(*this, shape_);
}

Tensor Tensor::astype(DType d) const {
  check(*this);
  return cast_to(*this, d);
}

// ---- Tensor: reductions ----

Tensor Tensor::sum(const Axes& axes, bool keepdims) const {
  check(*this);
  return reduce(dtype() == DType::Bool ? cast_to(*this, DType::Int32) : *this, Op::ReduceSum, axes, keepdims);
}

Tensor Tensor::mean(const Axes& axes, bool keepdims) const {
  check(*this);
  Tensor x = to_float(*this);
  Tensor s = x.sum(axes, keepdims);
  int64_t n = size() / numel(reduce(x, Op::ReduceSum, axes, true).shape());
  return s / detail::lift(s, static_cast<double>(n), false);
}

Tensor Tensor::max(const Axes& axes, bool keepdims) const { return reduce(*this, Op::ReduceMax, axes, keepdims); }

Tensor Tensor::min(const Axes& axes, bool keepdims) const {
  check(*this);
  // min(x) = -max(-x) for floats; for ints and bool use the complement, which cannot overflow
  Tensor flipped = is_float(dtype()) ? -*this
                   : dtype() == DType::Bool ? bool_not(*this)
                                            : wrap(*this, G(*this).alu(Op::Xor, {u_, G(*this).iconst(dtype(), -1, shape())}));
  Tensor m = reduce(flipped, Op::ReduceMax, axes, keepdims);
  return is_float(dtype()) ? -m : dtype() == DType::Bool ? bool_not(m)
                                                         : wrap(m, G(m).alu(Op::Xor, {m.uop(), G(m).iconst(dtype(), -1, m.shape())}));
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
  Axes red = norm_axes(axes, ndim());
  Axes perm;
  Shape kept;
  int64_t K = 1;
  for (int64_t k = 0; k < ndim(); k++)
    if (!std::binary_search(red.begin(), red.end(), k)) { perm.push_back(k); kept.push_back(shape()[static_cast<size_t>(k)]); }
  for (int64_t k : red) { perm.push_back(k); K *= shape()[static_cast<size_t>(k)]; }
  Shape flat = kept;
  flat.push_back(K);
  Tensor x = transpose(perm).reshape(flat);     // the reduced factors are the last axis, in row-major order
  Tensor acc = x.slice(static_cast<int64_t>(kept.size()), true, 0, true, 1, 1);
  for (int64_t k = 1; k < K; k++) acc = acc * x.slice(static_cast<int64_t>(kept.size()), true, k, true, k + 1, 1);
  Shape out;
  for (int64_t k = 0; k < ndim(); k++) {
    if (!std::binary_search(red.begin(), red.end(), k)) out.push_back(shape()[static_cast<size_t>(k)]);
    else if (keepdims) out.push_back(1);
  }
  return acc.reshape(out);
}

Tensor Tensor::cumsum(int64_t axis, bool exclusive, bool reverse) const {
  check(*this);
  axis = norm_axis(axis, ndim());
  const size_t a = static_cast<size_t>(axis);
  const int64_t S = shape()[a];
  // out[.., i, ..] = sum over j of x[.., j, ..] where j is in the window of i: j <= i (j < i when exclusive; j >= i when reverse)
  Shape xs = shape();
  xs.insert(xs.begin() + axis + 1, 1);                       // (.., S (j), 1 (i), ..)
  Shape js(static_cast<size_t>(ndim()) + 1, 1), is(js);
  js[a] = S;                                                 // the index j runs over axis a, i over axis a + 1
  is[a + 1] = S;
  Tensor j = session().arange(S, DType::Int64).reshape(js);
  Tensor i = session().arange(S, DType::Int64).reshape(is);
  Tensor in_window = reverse ? (exclusive ? j > i : j >= i) : (exclusive ? j < i : j <= i);
  // masked elements are the zero of the sum: -0.0 keeps the sign of the first element (an exclusive sum starts at +0); a scalar
  // constant, so that it broadcasts from the right
  Tensor fill(&session(), G(*this).constant(Scalar::from_double(dtype(), is_float(dtype()) && !exclusive ? -0.0 : 0.0)));
  Tensor picked = where(in_window, reshape(xs), fill);       // broadcast: (.., S (j), S (i), ..)
  return picked.sum(Axes{axis}, false);
}

// ---- Tensor: elementwise ----

Tensor Tensor::operator-() const {
  check(*this);
  return wrap(*this, G(*this).neg(u_));
}

Tensor Tensor::abs() const {
  check(*this);
  if (dtype() == DType::Bool) return *this;
  return where(*this < cst_t(*this, 0), -*this, *this);
}

Tensor Tensor::sqrt() const { return wrap(*this, G(*this).sqrt(to_float(*this).uop())); }
Tensor Tensor::sin() const { return wrap(*this, G(*this).sin(to_float(*this).uop())); }
Tensor Tensor::cos() const {
  Tensor x = to_float(*this);
  return wrap(x, G(x).sin((x + cst_t(x, kPi / 2)).uop()));
}
Tensor Tensor::exp() const {
  Tensor x = to_float(*this);
  return wrap(x, G(x).exp2((x * cst_t(x, kLog2E)).uop()));
}
Tensor Tensor::log() const {
  Tensor x = to_float(*this);
  return wrap(x, G(x).log2(x.uop())) * cst_t(x, kLn2);
}
Tensor Tensor::tanh() const {  // 1 - 2 / (exp(2x) + 1): exact limits +-1 where exp overflows or vanishes
  Tensor x = to_float(*this);
  return cst_t(x, 1) - cst_t(x, 2) / ((x * cst_t(x, 2)).exp() + cst_t(x, 1));
}
Tensor Tensor::sigmoid() const {
  Tensor x = to_float(*this);
  return cst_t(x, 1) / ((-x).exp() + cst_t(x, 1));
}
Tensor Tensor::log2() const { Tensor x = to_float(*this); return wrap(x, G(x).log2(x.uop())); }
Tensor Tensor::acos() const { Tensor x = to_float(*this); return wrap(x, G(x).acos(x.uop())); }
Tensor Tensor::acosh() const { Tensor x = to_float(*this); return wrap(x, G(x).acosh(x.uop())); }
Tensor Tensor::asin() const { Tensor x = to_float(*this); return wrap(x, G(x).asin(x.uop())); }
Tensor Tensor::asinh() const { Tensor x = to_float(*this); return wrap(x, G(x).asinh(x.uop())); }
Tensor Tensor::atan() const { Tensor x = to_float(*this); return wrap(x, G(x).atan(x.uop())); }
Tensor Tensor::atanh() const { Tensor x = to_float(*this); return wrap(x, G(x).atanh(x.uop())); }
Tensor Tensor::cosh() const { Tensor x = to_float(*this); return wrap(x, G(x).cosh(x.uop())); }
Tensor Tensor::sinh() const { Tensor x = to_float(*this); return wrap(x, G(x).sinh(x.uop())); }
Tensor Tensor::tan() const { Tensor x = to_float(*this); return wrap(x, G(x).tan(x.uop())); }
Tensor Tensor::expm1() const { Tensor x = to_float(*this); return wrap(x, G(x).expm1(x.uop())); }
Tensor Tensor::log1p() const { Tensor x = to_float(*this); return wrap(x, G(x).log1p(x.uop())); }
Tensor Tensor::log10() const { Tensor x = to_float(*this); return wrap(x, G(x).log10(x.uop())); }
Tensor Tensor::round() const {
  if (is_int(dtype())) return *this;
  Tensor x = to_float(*this);
  return wrap(x, G(x).round(x.uop()));
}
Tensor Tensor::relu() const {
  check(*this);
  return maximum(*this, cst_t(*this, 0));
}
Tensor Tensor::square() const {
  check(*this);
  return *this * *this;
}
Tensor Tensor::reciprocal() const {
  Tensor x = to_float(*this);
  return cst_t(x, 1) / x;
}
Tensor Tensor::softmax(int64_t axis) const {
  Tensor x = to_float(*this);
  Tensor e = (x - x.max(Axes{axis}, true)).exp();
  return e / e.sum(Axes{axis}, true);
}
Tensor Tensor::log_softmax(int64_t axis) const {
  Tensor x = to_float(*this);
  Tensor z = x - x.max(Axes{axis}, true);
  return z - z.exp().sum(Axes{axis}, true).log();
}
Tensor Tensor::clip(double lo, double hi) const {
  check(*this);
  return minimum(maximum(*this, detail::lift(*this, lo, false)), detail::lift(*this, hi, false));
}

Tensor Tensor::floor() const {
  check(*this);
  return is_float(dtype()) ? integral(*this, false) : *this;
}

Tensor Tensor::ceil() const {
  check(*this);
  return is_float(dtype()) ? integral(*this, true) : *this;
}

Tensor Tensor::isnan() const {
  check(*this);
  if (!is_float(dtype())) return wrap(*this, G(*this).constant(Scalar::from_int(DType::Bool, 0), shape()));
  return *this != *this;   // NaN is the one value unequal to itself (the symbolic simplifier keeps this)
}

Tensor Tensor::isinf() const {
  check(*this);
  if (!is_float(dtype())) return wrap(*this, G(*this).constant(Scalar::from_int(DType::Bool, 0), shape()));
  return abs() == cst_t(*this, std::numeric_limits<double>::infinity());
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
  return nfcuop::dump(u_);
}

// ---- Session ----

Tensor Session::from(const Array& a) {
  std::string name = "_buf" + std::to_string(next_buf_++);
  buffers_[name] = a;
  return Tensor(this, g_.var(name, a.dtype, a.shape));
}

Tensor Session::array(const std::vector<double>& v, DType d) {
  return array(v, Shape{static_cast<int64_t>(v.size())}, d);
}

Tensor Session::array(const std::vector<double>& v, const Shape& shape, DType d) {
  return from(Array::from_doubles(d, shape, v));
}

Tensor Session::array2d(const std::vector<std::vector<double>>& rows, DType d) {
  if (rows.empty() || rows[0].empty()) throw Error("np: array2d needs at least one element");
  std::vector<double> flat;
  for (const auto& r : rows) {
    if (r.size() != rows[0].size()) throw Error("np: array2d rows differ in length");
    flat.insert(flat.end(), r.begin(), r.end());
  }
  return array(flat, Shape{static_cast<int64_t>(rows.size()), static_cast<int64_t>(rows[0].size())}, d);
}

Tensor Session::scalar(double v, DType d) { return Tensor(this, g_.constant(Scalar::from_double(d, v))); }
Tensor Session::full(const Shape& shape, double v, DType d) { return Tensor(this, g_.constant(Scalar::from_double(d, v), shape)); }
Tensor Session::zeros(const Shape& shape, DType d) { return full(shape, 0, d); }
Tensor Session::ones(const Shape& shape, DType d) { return full(shape, 1, d); }

Tensor Session::arange(int64_t n, DType d) { return arange(0.0, static_cast<double>(n), 1.0, d); }

Tensor Session::arange(double start, double stop, double step, DType d) {
  if (step == 0) throw Error("np: arange with step 0");
  double count = std::ceil((stop - start) / step);
  if (!(count >= 1)) throw Error("np: arange would be empty (tensors need at least one element per dimension)");
  std::vector<double> v;
  for (int64_t k = 0; k < static_cast<int64_t>(count); k++) v.push_back(start + static_cast<double>(k) * step);
  return array(v, d);
}

Tensor Session::linspace(double start, double stop, int64_t num, DType d) {
  if (num < 1) throw Error("np: linspace needs at least one point");
  std::vector<double> v;
  for (int64_t k = 0; k < num; k++)
    v.push_back(num == 1 ? start : k == num - 1 ? stop : start + static_cast<double>(k) * (stop - start) / static_cast<double>(num - 1));
  return array(v, d);
}

Tensor Session::eye(int64_t n, DType d) {
  if (n < 1) throw Error("np: eye needs n >= 1");
  std::vector<double> v(static_cast<size_t>(n * n), 0.0);
  for (int64_t k = 0; k < n; k++) v[static_cast<size_t>(k * n + k)] = 1;
  return array(v, Shape{n, n}, d);
}

Tensor Session::placeholder(const std::string& name, const Shape& shape, DType d) {
  if (name.compare(0, 4, "_buf") == 0) throw Error("np: placeholder names starting with _buf are reserved");
  return Tensor(this, g_.var(name, d, shape));
}

Array Session::eval(const Tensor& t, const std::map<std::string, Array>& feeds) { return eval_all({t}, feeds)[0]; }

std::vector<Array> Session::eval_all(const std::vector<Tensor>& ts, const std::map<std::string, Array>& feeds) {
  if (backend == Backend::Ort) throw Error("ut: the ort back end runs an hir graph; evaluate through np::Session");
  if (backend == Backend::Tinygrad) throw Error("ut: the tinygrad back end runs an hir graph; evaluate through np::Session");
  if (ts.empty()) throw Error("np: eval_all needs at least one tensor");
  std::vector<const UOp*> roots;
  for (const Tensor& t : ts) {
    check(t);
    if (&t.session() != this) throw Error("np: tensor of another session");
    roots.push_back(optimize ? graph_rewrite(g_, symbolic(), t.uop()) : t.uop());
  }
  std::map<std::string, Array> env;
  for (const UOp* root : roots)
    for (const UOp* u : toposort(root)) {
      if (u->op != Op::Var) continue;
      auto f = feeds.find(u->name);
      if (f != feeds.end()) { env[u->name] = f->second; continue; }
      auto b = buffers_.find(u->name);
      if (b != buffers_.end()) env[u->name] = b->second;
    }
  std::vector<Array> out;
  if (backend == Backend::Interpreter) {
    for (const UOp* root : roots) out.push_back(evaluate_array(root, env));
    return out;
  }
  CProgram prog = render_c(roots);
  std::string key = cc + "\n" + prog.source;
  auto it = modules_.find(key);
  if (it == modules_.end()) it = modules_.emplace(key, CModule::compile(prog, cc)).first;
  last_program_ = prog;
  has_program_ = true;
  return it->second->run(env);
}

// ---- functions ----

Tensor where(const Tensor& cond, const Tensor& a, const Tensor& b) {
  same_session(a, b);
  check(cond);
  Tensor c = cond.dtype() == DType::Bool ? cond : cond != detail::lift(cond, 0, true);
  DType dt = promote(a.dtype(), b.dtype());
  Shape out = broadcast_shape(broadcast_shape(c.shape(), a.shape()), b.shape());
  Tensor ca = bcast(cast_to(c, DType::Bool), out), x = bcast(cast_to(a, dt), out), y = bcast(cast_to(b, dt), out);
  return wrap(ca, G(ca).where(ca.uop(), x.uop(), y.uop()));
}

Tensor maximum(const Tensor& a, const Tensor& b) { return arith(Op::Max, a, b); }
Tensor minimum(const Tensor& a, const Tensor& b) { return where(a < b, a, b); }

Tensor floor_divide(const Tensor& a, const Tensor& b) {
  DType dt;
  int_only(a, b, "floor_divide", dt);
  Tensor x = cast_to(a, dt), y = cast_to(b, dt);
  prepare(x, y, dt);
  Tensor q = wrap(x, G(x).idiv(x.uop(), y.uop()));
  Tensor r = wrap(x, G(x).mod(x.uop(), y.uop()));
  return q - cast_to(floor_adjust(r, y), dt);
}

Tensor remainder(const Tensor& a, const Tensor& b) {
  DType dt;
  int_only(a, b, "remainder", dt);
  Tensor x = cast_to(a, dt), y = cast_to(b, dt);
  prepare(x, y, dt);
  Tensor r = wrap(x, G(x).mod(x.uop(), y.uop()));
  return r + where(floor_adjust(r, y), y, cst_t(y, 0));
}

Tensor logical_not(const Tensor& a) {
  check(a);
  return a.dtype() == DType::Bool ? bool_not(a) : a == detail::lift(a, 0, true);
}

Tensor concatenate(const std::vector<Tensor>& ts, int64_t axis) {
  if (ts.empty()) throw Error("np: concatenate needs at least one tensor");
  const Tensor& first = ts[0];
  check(first);
  axis = norm_axis(axis, first.ndim());
  DType dt = first.dtype();
  for (const Tensor& t : ts) {
    same_session(first, t);
    if (t.ndim() != first.ndim()) throw Error("np: concatenate needs tensors of the same rank");
    for (int64_t k = 0; k < t.ndim(); k++)
      if (k != axis && t.shape()[k] != first.shape()[k]) throw Error("np: concatenate: shapes " + to_string(first.shape()) + " and " + to_string(t.shape()) + " differ off the axis");
    dt = promote(dt, t.dtype());
  }
  if (ts.size() == 1) return cast_to(first, dt);
  Graph& g = G(first);
  int64_t total = 0;
  for (const Tensor& t : ts) total += t.shape()[axis];
  // each part is padded to the full length with zeros; a padded Bool mask (false outside the part) picks the part, so the
  // result is exact (adding zeros would turn -0.0 into +0.0)
  const UOp* acc = nullptr;
  int64_t at = 0;
  for (size_t k = 0; k < ts.size(); k++) {
    Tensor t = cast_to(ts[k], dt);
    Shape before(t.ndim(), 0), after(t.ndim(), 0);
    before[axis] = at;
    after[axis] = total - at - t.shape()[axis];
    const UOp* part = g.pad(t.uop(), before, after);
    if (!acc) { acc = part; at += t.shape()[axis]; continue; }
    const UOp* mask = g.pad(g.iconst(DType::Bool, 1, t.shape()), before, after);
    acc = g.where(mask, part, acc);
    at += t.shape()[axis];
  }
  return wrap(first, acc);
}

Tensor trunc_divide(const Tensor& a, const Tensor& b) {
  DType dt;
  int_only(a, b, "trunc_divide", dt);
  Tensor x = cast_to(a, dt), y = cast_to(b, dt);
  prepare(x, y, dt);
  return wrap(x, G(x).idiv(x.uop(), y.uop()));
}

Tensor c_remainder(const Tensor& a, const Tensor& b) {
  DType dt;
  int_only(a, b, "c_remainder", dt);
  Tensor x = cast_to(a, dt), y = cast_to(b, dt);
  prepare(x, y, dt);
  return wrap(x, G(x).mod(x.uop(), y.uop()));
}

Tensor pow(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = promote(a.dtype(), b.dtype());
  if (dt == DType::Bool) dt = DType::Int32;
  Tensor x = a, y = b;
  prepare(x, y, dt);
  if (is_int(dt)) return int_pow(x, y);
  // exp(y log|x|) in float64; the cases C99 pow treats specially are then set by where, from the last to the first in the
  // order of their precedence
  const double inf = std::numeric_limits<double>::infinity();
  Tensor X = cast_to(x, DType::Float64), Y = cast_to(y, DType::Float64);
  Tensor r = (Y * X.abs().log()).exp();
  Tensor y_int = Y.floor() == Y;                               // false for NaN; +-inf counts as an integer, as in C
  Tensor y_odd = (Y - (Y * 0.5).floor() * 2.0) == 1.0;         // odd integers only (NaN and inf are not)
  Tensor x_negzero = (X == 0.0) & ((1.0 / X) < 0.0);
  Tensor x_neg = (X < 0.0) | x_negzero;                        // a negative base, a negative zero, or -inf
  r = where(x_neg & y_int & y_odd, -r, r);
  Tensor not_real = (X < 0.0) & (X != -inf) & (Y != Y.floor());   // a negative base to a non-integer power
  r = where(not_real, cst_t(r, std::numeric_limits<double>::quiet_NaN()), r);
  r = where((X == -1.0) & (Y.abs() == inf), cst_t(r, 1), r);   // (-1) ** +-inf
  r = where(X == 1.0, cst_t(r, 1), r);                          // 1 ** y, NaN included
  r = where(Y == 0.0, cst_t(r, 1), r);                          // x ** 0, NaN included
  return cast_to(r, dt);
}

Tensor argmax(const Tensor& x, int64_t axis, bool keepdims, bool last) { return arg_select(x, axis, keepdims, true, last); }
Tensor argmin(const Tensor& x, int64_t axis, bool keepdims, bool last) { return arg_select(x, axis, keepdims, false, last); }

Tensor matmul(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  if (a.ndim() < 1 || b.ndim() < 1) throw Error("np: matmul needs at least 1-D operands");
  const bool a1 = a.ndim() == 1, b1 = b.ndim() == 1;
  DType dt = promote(a.dtype(), b.dtype());
  if (dt == DType::Bool) dt = DType::Int32;
  Tensor A = cast_to(a1 ? a.reshape({1, a.shape()[0]}) : a, dt);
  Tensor B = cast_to(b1 ? b.reshape({b.shape()[0], 1}) : b, dt);
  const int64_t m = A.shape()[A.ndim() - 2], k = A.shape()[A.ndim() - 1];
  const int64_t k2 = B.shape()[B.ndim() - 2], n = B.shape()[B.ndim() - 1];
  if (k != k2) throw Error("np: matmul shapes " + to_string(a.shape()) + " and " + to_string(b.shape()) + " do not align");
  Shape sa(A.shape().begin(), A.shape().end() - 2), sb(B.shape().begin(), B.shape().end() - 2);
  sa.insert(sa.end(), {m, k, 1});
  sb.insert(sb.end(), {1, k, n});
  Tensor p = A.reshape(sa) * B.reshape(sb);              // batch..., m, k, n
  Tensor s = p.sum(Axes{p.ndim() - 2});                  // batch..., m, n
  Shape out(s.shape().begin(), s.shape().end());
  if (b1) out.pop_back();
  if (a1) out.erase(out.end() - (b1 ? 1 : 2));
  return out.empty() ? s.reshape({}) : s.reshape(out);
}

Tensor operator+(const Tensor& a, const Tensor& b) { return arith(Op::Add, a, b); }
Tensor operator-(const Tensor& a, const Tensor& b) { return arith(Op::Sub, a, b); }
Tensor operator*(const Tensor& a, const Tensor& b) { return arith(Op::Mul, a, b); }
Tensor operator/(const Tensor& a, const Tensor& b) {
  same_session(a, b);
  DType dt = promote(a.dtype(), b.dtype());
  if (!is_float(dt)) dt = DType::Float32;
  Tensor x = a, y = b;
  prepare(x, y, dt);
  return wrap(x, G(x).fdiv(x.uop(), y.uop()));
}
Tensor operator%(const Tensor& a, const Tensor& b) { return remainder(a, b); }
Tensor operator<(const Tensor& a, const Tensor& b) { return compare(Op::CmpLt, a, b); }
Tensor operator>(const Tensor& a, const Tensor& b) { return compare(Op::CmpLt, b, a); }
Tensor operator!=(const Tensor& a, const Tensor& b) { return compare(Op::CmpNe, a, b); }
Tensor operator==(const Tensor& a, const Tensor& b) { return bool_not(compare(Op::CmpNe, a, b)); }
Tensor operator<=(const Tensor& a, const Tensor& b) { return logic(Op::Or, compare(Op::CmpLt, a, b), a == b); }
Tensor operator>=(const Tensor& a, const Tensor& b) { return logic(Op::Or, compare(Op::CmpLt, b, a), a == b); }
Tensor operator&(const Tensor& a, const Tensor& b) { return logic(Op::And, a, b); }
Tensor operator|(const Tensor& a, const Tensor& b) { return logic(Op::Or, a, b); }
Tensor operator^(const Tensor& a, const Tensor& b) { return logic(Op::Xor, a, b); }

}  // namespace ut
}  // namespace nfcuop
