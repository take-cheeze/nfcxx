// nfcuop::poly: the numpy-like API for scripts (nfcuop_poly.hpp, docs/notes/uop-poly.md). Two script classes:
//   Tensor  an np::Tensor: shape, dtype, ndim, size and T as properties; every member of np::Tensor as a method; the operators
//           as Python-named methods (__add__, __radd__, ...), which the backends turn into the operators of their language, and
//           as named methods (add, sub, mul, div, mod, lt, ...) for the languages without operator overloading.
//   NumPy   an np::Session: array, zeros, ..., eval, to_onnx, and the free functions of nfcuop_np.hpp. The global `np` is one.
// Script values come in as nfcpoly::Value (any script value) and are decoded here: numbers next to tensors are weak scalars like
// the C++ API's scalar overloads, nested lists become arrays, a dtype is a name ("float32"), a shape an integer or a list.
//
// The file is empty unless nfcpoly.hpp is on the include path (-I lib/poly), so that building lib/uop/nfcuop*.cpp without nfcpoly,
// as the other tests of lib/uop do, keeps working; with it, link lib/poly/nfcpoly.cpp and the backends of the languages used.
#if __has_include("nfcpoly.hpp")
#include "nfcuop_poly.hpp"

#include <cmath>
#include <cstdlib>
#include <map>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace nfcuop {
namespace poly {

namespace {

using nfcpoly::Value;
using nfcpoly::detail::Var;
using np::Axes;
using np::Session;
using np::Tensor;

// The placeholders made through one NumPy object, by name: eval's feeds name them, and the data takes the placeholder's dtype.
struct State {
  std::map<std::string, Tensor> inputs;
};

struct NumPy {
  Session* s = nullptr;
  std::shared_ptr<State> st;
  // dtype names as properties, so that a script writes np.array(x, np.float64)
  std::string float32 = "float32", float64 = "float64", int32 = "int32", int64 = "int64", bool_ = "bool";
};

[[noreturn]] void fail(const std::string& m) { throw Error("np: " + m); }

// ---- decoding script values ------------------------------------------------------------------------------------------
const Tensor* tensor_of(const Value& v) {
  if (v.is_nil() || v.is_bool() || v.is_int() || v.is_float() || v.is_string() || v.is_array()) return nullptr;
  try {
    return v.as<const Tensor*>();
  } catch (const nfcpoly::ConversionError&) {
    return nullptr;  // an object of another class, or a script value that is not a host object
  }
}

bool truthy(const Value& v) {  // an omitted (nil) flag is false
  if (v.is_nil()) return false;
  if (v.is_bool()) return v.as<bool>();
  if (v.is_int()) return v.as<long long>() != 0;
  fail("expected true or false, got " + v.class_name());
}

double number_of(const Value& v, const char* what) {
  if (v.is_bool()) return v.as<bool>() ? 1 : 0;
  if (v.is_int()) return static_cast<double>(v.as<long long>());
  if (v.is_float()) return v.as<double>();
  fail(std::string(what) + ": expected a number, got " + (v.is_nil() ? "nil" : v.class_name()));
}

int64_t int_of(const Value& v, const char* what) {
  if (v.is_int()) return v.as<long long>();
  if (v.is_float()) {
    double d = v.as<double>();
    if (d == std::floor(d) && std::fabs(d) < 9e18) return static_cast<int64_t>(d);  // 3.0 is 3 (JavaScript has one number type)
  }
  fail(std::string(what) + ": expected an integer, got " + (v.is_nil() ? "nil" : v.class_name()));
}

DType dtype_named(const std::string& n) {
  if (n == "float32") return DType::Float32;
  if (n == "float64") return DType::Float64;
  if (n == "int32") return DType::Int32;
  if (n == "int64") return DType::Int64;
  if (n == "bool" || n == "bool_") return DType::Bool;
  fail("unknown dtype '" + n + "' (bool, int32, int64, float32, float64)");
}

std::optional<DType> opt_dtype(const Value& v) {
  if (v.is_nil()) return std::nullopt;
  if (!v.is_string()) fail("a dtype is a name such as \"float32\", got " + v.class_name());
  return dtype_named(v.as<std::string>());
}

std::vector<Value> items_of(const Value& v) { return v.as<std::vector<Value>>(); }

Axes axes_of(const Value& v) {  // nil: all axes; an integer; a list of integers
  if (v.is_nil()) return {};
  if (!v.is_array()) return {int_of(v, "axis")};
  Axes out;
  for (const Value& e : items_of(v)) out.push_back(int_of(e, "axis"));
  return out;
}

Shape shape_of(const Value& v) {  // an integer or a list of integers
  if (v.is_nil()) fail("a shape is needed");
  if (!v.is_array()) return {int_of(v, "shape")};
  Shape out;
  for (const Value& e : items_of(v)) out.push_back(int_of(e, "shape"));
  return out;
}

// Dimensions or axes given as one list or as separate arguments: t.reshape([2, 3]) and t.reshape(2, 3).
Shape dims_of(const Value* a, int n) {
  if (a[0].is_array()) {
    for (int k = 1; k < n; k++)
      if (!a[k].is_nil()) fail("give the dimensions as one list or as separate integers, not both");
    return shape_of(a[0]);
  }
  Shape out;
  for (int k = 0; k < n && !a[k].is_nil(); k++) out.push_back(int_of(a[k], "dimension"));
  return out;
}

// ---- nested lists -----------------------------------------------------------------------------------------------------
struct Walk {
  std::vector<double> flat;
  Shape shape;
  int leaf = -1;  // the depth numbers are found at
};

void walk(const Value& x, size_t depth, Walk& w) {
  if (x.is_array()) {
    std::vector<Value> items = items_of(x);
    if (items.empty()) fail("an empty list (tensors need at least one element per dimension)");
    if (w.leaf >= 0 && static_cast<int>(depth) >= w.leaf) fail("ragged nested list");
    if (depth == w.shape.size()) w.shape.push_back(static_cast<int64_t>(items.size()));
    else if (w.shape[depth] != static_cast<int64_t>(items.size())) fail("ragged nested list");
    for (const Value& e : items) walk(e, depth + 1, w);
    return;
  }
  if (w.leaf < 0) {
    if (w.shape.size() != depth) fail("ragged nested list");
    w.leaf = static_cast<int>(depth);
  } else if (w.leaf != static_cast<int>(depth)) {
    fail("ragged nested list");
  }
  w.flat.push_back(number_of(x, "array element"));
}

Tensor tensor_from(Session& s, const Value& v, std::optional<DType> d) {
  if (const Tensor* t = tensor_of(v)) return d ? t->astype(*d) : *t;
  Walk w;
  walk(v, 0, w);
  return s.array(w.flat, w.shape, d);
}

Var scalar_var(const Scalar& x) {
  switch (x.dtype) {
    case DType::Bool: return Var::boolean(x.i != 0);
    case DType::Int32: case DType::Int64: return Var::integer(x.i);
    default: return Var::real(x.f);
  }
}
Var nested_var(const Array& a, size_t dim, size_t& pos) {
  if (dim == a.shape.size()) return scalar_var(a.data[pos++]);
  std::vector<Var> items;
  items.reserve(static_cast<size_t>(a.shape[dim]));
  for (int64_t k = 0; k < a.shape[dim]; k++) items.push_back(nested_var(a, dim + 1, pos));
  return Var::array(std::move(items));
}
Value nested(const Array& a) {
  size_t pos = 0;
  return Value(nested_var(a, 0, pos));
}
Value flat_list(const Array& a) {
  std::vector<Var> items;
  for (const Scalar& x : a.data) items.push_back(scalar_var(x));
  return Value(Var::array(std::move(items)));
}

// ---- operands ---------------------------------------------------------------------------------------------------------
// A number next to `like` is a weak scalar, as in the C++ operators; a list becomes an array.
Tensor operand(const Value& v, const Tensor& like) {
  if (const Tensor* t = tensor_of(v)) return *t;
  if (v.is_bool()) return np::detail::lift(like, v.as<bool>() ? 1 : 0, true);
  if (v.is_int()) return np::detail::lift(like, static_cast<double>(v.as<long long>()), true);
  if (v.is_float()) return np::detail::lift(like, v.as<double>(), false);
  if (v.is_array()) return tensor_from(like.session(), v, std::nullopt);
  fail("unsupported operand " + (v.is_nil() ? std::string("nil") : v.class_name()));
}

// A tensor from anything: a Tensor, a list, a number (default_int for an integer, default_float otherwise).
Tensor as_tensor(Session& s, const Value& v) {
  if (v.is_bool() || v.is_int()) return s.scalar(number_of(v, "value"), s.default_int);
  if (v.is_float()) return s.scalar(v.as<double>());
  return tensor_from(s, v, std::nullopt);
}

std::pair<Tensor, Tensor> pair_of(Session& s, const Value& a, const Value& b) {
  const Tensor* ta = tensor_of(a);
  const Tensor* tb = tensor_of(b);
  if (ta && tb) return {*ta, *tb};
  if (ta) return {*ta, operand(b, *ta)};
  if (tb) return {operand(a, *tb), *tb};
  return {as_tensor(s, a), as_tensor(s, b)};
}

std::vector<Tensor> tensors_of(Session& s, const Value& v) {
  if (!v.is_array()) fail("expected a list of tensors");
  std::vector<Tensor> out;
  for (const Value& e : items_of(v)) out.push_back(as_tensor(s, e));
  return out;
}

// ---- indexing: t[i], t[1:3], t[:, 0] --------------------------------------------------------------------------------
// One entry of an index. An integer picks along the axis and drops it; a slice keeps the axis; nil takes the whole axis. A slice
// is Python's slice object, a Ruby Range, or a list [start, stop] / [start, stop, step] with nil for an omitted bound.
bool slice_of(const Value& v, int64_t dim, int64_t out[3]) {
  const int64_t none = np::None;
  out[0] = out[1] = none;
  out[2] = 1;
  if (v.is_array()) {
    std::vector<Value> p = items_of(v);
    if (p.size() < 2 || p.size() > 3) fail("a slice is [start, stop] or [start, stop, step]");
    if (!p[0].is_nil()) out[0] = int_of(p[0], "slice start");
    if (!p[1].is_nil()) out[1] = int_of(p[1], "slice stop");
    if (p.size() == 3 && !p[2].is_nil()) out[2] = int_of(p[2], "slice step");
    return true;
  }
  if (v.is_string()) {  // "1:3", ":", "::-1", "2:": Python's slice syntax as text, for the languages without a slice literal
    const std::string text = v.as<std::string>();
    size_t c1 = text.find(':');
    if (c1 == std::string::npos) fail("a slice string looks like \"start:stop\" or \"start:stop:step\", got '" + text + "'");
    size_t c2 = text.find(':', c1 + 1);
    std::string part[3] = {text.substr(0, c1), text.substr(c1 + 1, c2 == std::string::npos ? std::string::npos : c2 - c1 - 1),
                           c2 == std::string::npos ? "" : text.substr(c2 + 1)};
    for (int k = 0; k < 3; k++) {
      size_t b = part[k].find_first_not_of(" ");
      if (b == std::string::npos) continue;  // omitted
      char* end = nullptr;
      long long n = std::strtoll(part[k].c_str() + b, &end, 10);
      while (end && *end == ' ') end++;
      if (end == part[k].c_str() + b || (end && *end)) fail("bad slice string '" + text + "'");
      out[k] = n;
    }
    return true;
  }
  const std::string cn = v.class_name();
  if (cn == "slice") {  // Python: slice.indices(dim) clips and resolves negatives
    std::vector<long long> r = v.call("indices", static_cast<long long>(dim)).as<std::vector<long long>>();
    if (r.size() != 3) fail("bad slice");
    out[0] = r[0];
    out[1] = r[1];
    out[2] = r[2];
    if (out[2] < 0 && out[1] < 0) out[1] = none;  // [::-1] resolves to (dim - 1, -1, -1): the -1 is "before the first"
    return true;
  }
  if (cn == "Range") {  // Ruby: a..b includes b, a...b does not
    Value b = v.call("begin"), e = v.call("end");
    bool excl = truthy(v.call("exclude_end?"));
    if (!b.is_nil()) out[0] = int_of(b, "range start");
    if (!e.is_nil()) {
      int64_t last = int_of(e, "range end");
      out[1] = excl ? last : (last == -1 ? none : last + 1);
    }
    return true;
  }
  return false;
}

Tensor index_with(const Tensor& t, const std::vector<Value>& items_in) {
  std::vector<Value> items = items_in;
  while (!items.empty() && items.back().is_nil()) items.pop_back();  // omitted trailing arguments
  Tensor cur = t;
  int64_t ax = 0;
  for (const Value& it : items) {
    if (ax >= cur.ndim()) fail("too many indices for a tensor of " + std::to_string(cur.ndim()) + " dimensions");
    int64_t sl[3];
    if (it.is_nil()) {
      ax++;
    } else if (it.is_int()) {
      cur = cur.at(it.as<long long>(), ax);
    } else if (int64_t dim = cur.shape()[static_cast<size_t>(ax)]; slice_of(it, dim, sl)) {
      // a slice that takes the whole axis (":", "0:", "::1") adds no node to the graph
      bool whole = sl[2] == 1 && (sl[0] == np::None || sl[0] == 0 || sl[0] <= -dim) && (sl[1] == np::None || sl[1] >= dim);
      if (!whole) cur = cur.slice(ax, sl[0], sl[1], sl[2]);
      ax++;
    } else {
      fail("an index is an integer, a slice or nil, got " + it.class_name());
    }
  }
  return cur;
}

// The Value arguments after the object, as a vector (nil padding kept).
template <class... V>
std::vector<Value> pack(const V&... v) {
  return std::vector<Value>{v...};
}

// ---- Tensor -----------------------------------------------------------------------------------------------------------
using BinFn = Tensor (*)(const Tensor&, const Tensor&);

// name: a named method; fwd, rev: the Python operator names (null: none). All take a tensor, a number or a list.
void def_binary(nfcpoly::ClassBuilder<Tensor>& b, const char* name, const char* fwd, const char* rev, BinFn f) {
  auto forward = [f](const Tensor& a, const Value& o) { return f(a, operand(o, a)); };
  b.method_fn(name, forward);
  if (fwd) b.method_fn(fwd, forward);
  if (rev) b.method_fn(rev, [f](const Tensor& a, const Value& o) { return f(operand(o, a), a); });
}

using UnFn = Tensor (Tensor::*)() const;
void def_unary(nfcpoly::ClassBuilder<Tensor>& b, const char* name, UnFn f) {
  b.method_fn(name, [f](const Tensor& t) { return (t.*f)(); });
}

void def_tensor(nfcpoly::ClassBuilder<Tensor> b) {
  def_binary(b, "add", "__add__", "__radd__", [](const Tensor& x, const Tensor& y) { return x + y; });
  def_binary(b, "sub", "__sub__", "__rsub__", [](const Tensor& x, const Tensor& y) { return x - y; });
  def_binary(b, "mul", "__mul__", "__rmul__", [](const Tensor& x, const Tensor& y) { return x * y; });
  def_binary(b, "div", "__truediv__", "__rtruediv__", [](const Tensor& x, const Tensor& y) { return x / y; });
  def_binary(b, "mod", "__mod__", "__rmod__", [](const Tensor& x, const Tensor& y) { return x % y; });
  def_binary(b, "floor_divide", "__floordiv__", "__rfloordiv__", [](const Tensor& x, const Tensor& y) { return np::floor_divide(x, y); });
  def_binary(b, "matmul", "__matmul__", "__rmatmul__", [](const Tensor& x, const Tensor& y) { return np::matmul(x, y); });
  def_binary(b, "dot", nullptr, nullptr, [](const Tensor& x, const Tensor& y) { return np::dot(x, y); });
  def_binary(b, "maximum", nullptr, nullptr, [](const Tensor& x, const Tensor& y) { return np::maximum(x, y); });
  def_binary(b, "minimum", nullptr, nullptr, [](const Tensor& x, const Tensor& y) { return np::minimum(x, y); });
  // comparisons: `2 < t` reaches Python as t.__gt__(2), so there are no reflected names
  def_binary(b, "lt", "__lt__", nullptr, [](const Tensor& x, const Tensor& y) { return x < y; });
  def_binary(b, "gt", "__gt__", nullptr, [](const Tensor& x, const Tensor& y) { return x > y; });
  def_binary(b, "le", "__le__", nullptr, [](const Tensor& x, const Tensor& y) { return x <= y; });
  def_binary(b, "ge", "__ge__", nullptr, [](const Tensor& x, const Tensor& y) { return x >= y; });
  def_binary(b, "eq", "__eq__", nullptr, [](const Tensor& x, const Tensor& y) { return x == y; });
  def_binary(b, "ne", "__ne__", nullptr, [](const Tensor& x, const Tensor& y) { return x != y; });
  def_binary(b, "and_", "__and__", "__rand__", [](const Tensor& x, const Tensor& y) { return x & y; });
  def_binary(b, "or_", "__or__", "__ror__", [](const Tensor& x, const Tensor& y) { return x | y; });
  def_binary(b, "xor", "__xor__", "__rxor__", [](const Tensor& x, const Tensor& y) { return x ^ y; });

  b.method_fn("neg", [](const Tensor& t) { return -t; });
  b.method_fn("__neg__", [](const Tensor& t) { return -t; });
  b.method_fn("__abs__", [](const Tensor& t) { return t.abs(); });
  b.method_fn("logical_not", [](const Tensor& t) { return np::logical_not(t); });
  def_unary(b, "abs", &Tensor::abs);
  def_unary(b, "sqrt", &Tensor::sqrt);
  def_unary(b, "exp", &Tensor::exp);
  def_unary(b, "log", &Tensor::log);
  def_unary(b, "sin", &Tensor::sin);
  def_unary(b, "cos", &Tensor::cos);
  def_unary(b, "tanh", &Tensor::tanh);
  def_unary(b, "sigmoid", &Tensor::sigmoid);
  def_unary(b, "relu", &Tensor::relu);
  def_unary(b, "square", &Tensor::square);
  def_unary(b, "reciprocal", &Tensor::reciprocal);
  b.method_fn("softmax", [](const Tensor& t, const Value& axis) { return t.softmax(axis.is_nil() ? -1 : int_of(axis, "axis")); }, 0);
  b.method_fn("log_softmax", [](const Tensor& t, const Value& axis) { return t.log_softmax(axis.is_nil() ? -1 : int_of(axis, "axis")); }, 0);
  b.method_fn("clip", [](const Tensor& t, const Value& lo, const Value& hi) {
    return t.clip(number_of(lo, "clip"), number_of(hi, "clip"));
  });

  // reductions: (axis = nil: all of them, keepdims = false)
  b.method_fn("sum", [](const Tensor& t, const Value& a, const Value& k) { return t.sum(axes_of(a), truthy(k)); }, 0);
  b.method_fn("mean", [](const Tensor& t, const Value& a, const Value& k) { return t.mean(axes_of(a), truthy(k)); }, 0);
  b.method_fn("max", [](const Tensor& t, const Value& a, const Value& k) { return t.max(axes_of(a), truthy(k)); }, 0);
  b.method_fn("min", [](const Tensor& t, const Value& a, const Value& k) { return t.min(axes_of(a), truthy(k)); }, 0);
  b.method_fn("var", [](const Tensor& t, const Value& a, const Value& k) { return t.var(axes_of(a), truthy(k)); }, 0);
  b.method_fn("std", [](const Tensor& t, const Value& a, const Value& k) { return t.stddev(axes_of(a), truthy(k)); }, 0);
  b.method_fn("stddev", [](const Tensor& t, const Value& a, const Value& k) { return t.stddev(axes_of(a), truthy(k)); }, 0);

  // shape
  b.method_fn("reshape", [](const Tensor& t, const Value& a, const Value& b2, const Value& c, const Value& d, const Value& e, const Value& f) {
    Value dims[] = {a, b2, c, d, e, f};
    return t.reshape(dims_of(dims, 6));
  }, 1);
  b.method_fn("transpose", [](const Tensor& t, const Value& a, const Value& b2, const Value& c, const Value& d, const Value& e, const Value& f) {
    Value dims[] = {a, b2, c, d, e, f};
    Axes perm = dims_of(dims, 6);
    return perm.empty() ? t.transpose() : t.transpose(perm);
  }, 0);
  b.property_fn("T", [](const Tensor& t) { return t.transpose(); });
  b.method_fn("swapaxes", [](const Tensor& t, const Value& a, const Value& c) { return t.swapaxes(int_of(a, "axis"), int_of(c, "axis")); });
  b.method_fn("flatten", [](const Tensor& t) { return t.flatten(); });
  b.method_fn("ravel", [](const Tensor& t) { return t.ravel(); });
  b.method_fn("squeeze", [](const Tensor& t, const Value& a) { return a.is_nil() ? t.squeeze() : t.squeeze(int_of(a, "axis")); }, 0);
  b.method_fn("expand_dims", [](const Tensor& t, const Value& a) { return t.expand_dims(int_of(a, "axis")); });
  b.method_fn("broadcast_to", [](const Tensor& t, const Value& a) { return t.broadcast_to(shape_of(a)); });
  b.method_fn("astype", [](const Tensor& t, const Value& d) {
    std::optional<DType> dt = opt_dtype(d);
    if (!dt) fail("astype needs a dtype");
    return t.astype(*dt);
  });
  // a[start:stop:step] along one axis; nil omits a bound
  b.method_fn("slice", [](const Tensor& t, const Value& axis, const Value& start, const Value& stop, const Value& step) {
    auto bound = [](const Value& v, const char* what) { return v.is_nil() ? np::None : int_of(v, what); };
    return t.slice(int_of(axis, "axis"), bound(start, "start"), bound(stop, "stop"), step.is_nil() ? 1 : int_of(step, "step"));
  }, 1);
  b.method_fn("at", [](const Tensor& t, const Value& index, const Value& axis) {
    return t.at(int_of(index, "index"), axis.is_nil() ? 0 : int_of(axis, "axis"));
  }, 1);
  b.method_fn("flip", [](const Tensor& t, const Value& axis) { return t.flip(axis.is_nil() ? 0 : int_of(axis, "axis")); }, 0);
  // t.index(i, [start, stop], nil, ...): several axes at once, the entries of Python's t[i, a:b, :]
  b.method_fn("index", [](const Tensor& t, const Value& a, const Value& b2, const Value& c, const Value& d) {
    return index_with(t, pack(a, b2, c, d));
  }, 1);
  b.method_fn("__getitem__", [](const Tensor& t, const Value& a, const Value& b2, const Value& c, const Value& d) {
    if (a.is_array() && b2.is_nil() && c.is_nil() && d.is_nil()) return index_with(t, items_of(a));  // Python's t[i, j] is one tuple
    return index_with(t, pack(a, b2, c, d));
  }, 1);

  // properties
  b.property_fn("shape", [](const Tensor& t) -> std::vector<int64_t> { return t.shape(); });
  b.property_fn("ndim", [](const Tensor& t) -> int64_t { return t.ndim(); });
  b.property_fn("size", [](const Tensor& t) -> int64_t { return t.size(); });
  b.property_fn("dtype", [](const Tensor& t) -> std::string { return name(t.dtype()); });

  // realization
  b.method_fn("numpy", [](const Tensor& t) { return nested(t.session().eval(t)); });
  b.method_fn("tolist", [](const Tensor& t) { return nested(t.session().eval(t)); });
  b.method_fn("values", [](const Tensor& t) { return flat_list(t.session().eval(t)); });
  b.method_fn("item", [](const Tensor& t) {
    Array a = t.session().eval(t);
    if (a.data.size() != 1) fail("item() needs a tensor of one element, got shape " + to_string(a.shape));
    return Value(scalar_var(a.data[0]));
  });
  auto str = [](const Tensor& t) { return t.str(); };
  b.method_fn("str", str);
  b.method_fn("toString", str);  // JavaScript's String(t)
  b.method_fn("__str__", str);
  b.method_fn("__repr__", str);
  b.method_fn("dump", [](const Tensor& t) { return t.dump(); });
  b.method_fn("dump_uops", [](const Tensor& t) { return t.dump_uops(); });
}

// ---- NumPy ------------------------------------------------------------------------------------------------------------
std::map<std::string, Array> feeds_of(const NumPy& n, const Value& v) {
  std::map<std::string, Array> out;
  if (v.is_nil()) return out;
  if (!v.is_array()) fail("feeds are a list of [name, data] pairs");
  for (const Value& pair : items_of(v)) {
    std::vector<Value> kv = pair.is_array() ? items_of(pair) : std::vector<Value>();
    if (kv.size() != 2 || !kv[0].is_string()) fail("feeds are a list of [name, data] pairs");
    std::string name = kv[0].as<std::string>();
    auto it = n.st->inputs.find(name);
    if (it == n.st->inputs.end()) fail("no placeholder named '" + name + "'");
    if (const Tensor* t = tensor_of(kv[1])) {
      out[name] = n.s->eval(*t);
    } else {
      Walk w;
      walk(kv[1], 0, w);
      out[name] = Array::from_doubles(it->second.dtype(), w.shape, w.flat);
    }
  }
  return out;
}

std::vector<std::pair<std::string, Tensor>> outputs_of(const NumPy& n, const Value& v) {
  std::vector<std::pair<std::string, Tensor>> out;
  if (!v.is_array()) fail("outputs are a list of [name, tensor] pairs");
  for (const Value& pair : items_of(v)) {
    std::vector<Value> kv = pair.is_array() ? items_of(pair) : std::vector<Value>();
    if (kv.size() != 2 || !kv[0].is_string()) fail("outputs are a list of [name, tensor] pairs");
    out.emplace_back(kv[0].as<std::string>(), as_tensor(*n.s, kv[1]));
  }
  return out;
}

void def_numpy(nfcpoly::ClassBuilder<NumPy> b) {
  b.field("float32", &NumPy::float32).field("float64", &NumPy::float64).field("int32", &NumPy::int32);
  b.field("int64", &NumPy::int64).field("bool_", &NumPy::bool_);

  // configuration: the defaults and the evaluation backend of the Session
  b.property_fn("default_float", [](const NumPy& n) -> std::string { return name(n.s->default_float); },
                [](NumPy& n, const std::string& v) {
                  DType d = dtype_named(v);
                  if (!is_float(d)) fail("default_float must be float32 or float64");
                  n.s->default_float = d;
                });
  b.property_fn("default_int", [](const NumPy& n) -> std::string { return name(n.s->default_int); },
                [](NumPy& n, const std::string& v) {
                  DType d = dtype_named(v);
                  if (!is_int(d)) fail("default_int must be int32 or int64");
                  n.s->default_int = d;
                });
  b.property_fn("backend", [](const NumPy& n) -> std::string { return n.s->backend == ut::Session::Backend::C ? "c" : "interpreter"; },
                [](NumPy& n, const std::string& v) {
                  if (v == "c") n.s->backend = ut::Session::Backend::C;
                  else if (v == "interpreter") n.s->backend = ut::Session::Backend::Interpreter;
                  else fail("backend is \"interpreter\" or \"c\", got '" + v + "'");
                });
  b.property_fn("cc", [](const NumPy& n) -> std::string { return n.s->cc; }, [](NumPy& n, const std::string& v) { n.s->cc = v; });
  b.property_fn("optimize", [](const NumPy& n) -> bool { return n.s->optimize; }, [](NumPy& n, bool v) { n.s->optimize = v; });

  // creation
  b.method_fn("array", [](const NumPy& n, const Value& data, const Value& dtype) { return tensor_from(*n.s, data, opt_dtype(dtype)); }, 1);
  b.method_fn("array2d", [](const NumPy& n, const Value& data, const Value& dtype) { return tensor_from(*n.s, data, opt_dtype(dtype)); }, 1);
  b.method_fn("scalar", [](const NumPy& n, const Value& v, const Value& dtype) { return n.s->scalar(number_of(v, "scalar"), opt_dtype(dtype)); }, 1);
  b.method_fn("zeros", [](const NumPy& n, const Value& shape, const Value& dtype) { return n.s->zeros(shape_of(shape), opt_dtype(dtype)); }, 1);
  b.method_fn("ones", [](const NumPy& n, const Value& shape, const Value& dtype) { return n.s->ones(shape_of(shape), opt_dtype(dtype)); }, 1);
  b.method_fn("full", [](const NumPy& n, const Value& shape, const Value& v, const Value& dtype) {
    bool integral = v.is_int() || v.is_bool();  // like numpy, the type of the value picks default_int or default_float
    std::optional<DType> d = opt_dtype(dtype);
    return n.s->full_impl(shape_of(shape), number_of(v, "full"), d ? *d : integral ? n.s->default_int : n.s->default_float);
  }, 2);
  // arange(stop), arange(start, stop), arange(start, stop, step), each with a dtype name at the end
  b.method_fn("arange", [](const NumPy& n, const Value& a, const Value& b2, const Value& c, const Value& d) {
    std::vector<Value> args = pack(a, b2, c, d);
    std::optional<DType> dt;
    while (!args.empty() && (args.back().is_nil() || args.back().is_string())) {
      if (args.back().is_string()) dt = opt_dtype(args.back());
      args.pop_back();
    }
    if (args.empty() || args.size() > 3) fail("arange takes (stop), (start, stop) or (start, stop, step), then an optional dtype");
    bool ints = true;
    std::vector<double> x;
    for (const Value& v : args) {
      if (v.is_float()) ints = false;
      x.push_back(number_of(v, "arange"));
    }
    double start = args.size() == 1 ? 0 : x[0], stop = args.size() == 1 ? x[0] : x[1], step = args.size() == 3 ? x[2] : 1;
    return n.s->arange_impl(start, stop, step, dt ? *dt : ints ? n.s->default_int : n.s->default_float);
  }, 1);
  b.method_fn("linspace", [](const NumPy& n, const Value& start, const Value& stop, const Value& num, const Value& dtype) {
    return n.s->linspace(number_of(start, "linspace"), number_of(stop, "linspace"), int_of(num, "num"), opt_dtype(dtype));
  }, 3);
  b.method_fn("eye", [](const NumPy& n, const Value& k, const Value& dtype) { return n.s->eye(int_of(k, "n"), opt_dtype(dtype)); }, 1);
  b.method_fn("placeholder", [](const NumPy& n, const Value& name, const Value& shape, const Value& dtype) {
    if (!name.is_string()) fail("a placeholder needs a name");
    Tensor t = n.s->placeholder(name.as<std::string>(), shape_of(shape), opt_dtype(dtype));
    n.st->inputs[name.as<std::string>()] = t;
    return t;
  }, 2);

  // evaluation and export
  b.method_fn("eval", [](const NumPy& n, const Value& t, const Value& feeds) {
    return nested(n.s->eval(as_tensor(*n.s, t), feeds_of(n, feeds)));
  }, 1);
  b.method_fn("eval_all", [](const NumPy& n, const Value& ts, const Value& feeds) {
    std::vector<Array> r = n.s->eval_all(tensors_of(*n.s, ts), feeds_of(n, feeds));
    std::vector<Var> out;
    for (const Array& a : r) out.push_back(nested(a).var());
    return Value(Var::array(std::move(out)));
  }, 1);
  b.method_fn("to_onnx", [](const NumPy& n, const Value& outputs, const Value& graph_name) {
    return n.s->to_onnx(outputs_of(n, outputs), graph_name.is_nil() ? std::string("nfcuop") : graph_name.as<std::string>());
  }, 1);
  b.method_fn("save_onnx", [](const NumPy& n, const Value& path, const Value& outputs) {
    if (!path.is_string()) fail("save_onnx needs a path");
    n.s->save_onnx(path.as<std::string>(), outputs_of(n, outputs));
  });

  // the free functions of nfcuop_np.hpp
  b.method_fn("where", [](const NumPy& n, const Value& c, const Value& a, const Value& b2) {
    std::pair<Tensor, Tensor> ab = pair_of(*n.s, a, b2);
    return np::where(as_tensor(*n.s, c), ab.first, ab.second);
  });
  b.method_fn("maximum", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::maximum(p.first, p.second); });
  b.method_fn("minimum", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::minimum(p.first, p.second); });
  b.method_fn("floor_divide", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::floor_divide(p.first, p.second); });
  b.method_fn("remainder", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::remainder(p.first, p.second); });
  b.method_fn("matmul", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::matmul(p.first, p.second); });
  b.method_fn("dot", [](const NumPy& n, const Value& a, const Value& b2) { auto p = pair_of(*n.s, a, b2); return np::dot(p.first, p.second); });
  b.method_fn("logical_not", [](const NumPy& n, const Value& a) { return np::logical_not(as_tensor(*n.s, a)); });
  b.method_fn("concatenate", [](const NumPy& n, const Value& ts, const Value& axis) {
    return np::concatenate(tensors_of(*n.s, ts), axis.is_nil() ? 0 : int_of(axis, "axis"));
  }, 1);
  b.method_fn("stack", [](const NumPy& n, const Value& ts, const Value& axis) {
    return np::stack(tensors_of(*n.s, ts), axis.is_nil() ? 0 : int_of(axis, "axis"));
  }, 1);
  b.method_fn("softmax", [](const NumPy& n, const Value& a, const Value& axis) {
    return np::softmax(as_tensor(*n.s, a), axis.is_nil() ? -1 : int_of(axis, "axis"));
  }, 1);
  b.method_fn("log_softmax", [](const NumPy& n, const Value& a, const Value& axis) {
    return as_tensor(*n.s, a).log_softmax(axis.is_nil() ? -1 : int_of(axis, "axis"));
  }, 1);
  b.method_fn("clip", [](const NumPy& n, const Value& a, const Value& lo, const Value& hi) {
    return as_tensor(*n.s, a).clip(number_of(lo, "clip"), number_of(hi, "clip"));
  });
#define NFCUOP_POLY_UNARY(NAME) \
  b.method_fn(#NAME, [](const NumPy& n, const Value& a) { return as_tensor(*n.s, a).NAME(); });
  NFCUOP_POLY_UNARY(abs)
  NFCUOP_POLY_UNARY(sqrt)
  NFCUOP_POLY_UNARY(exp)
  NFCUOP_POLY_UNARY(log)
  NFCUOP_POLY_UNARY(sin)
  NFCUOP_POLY_UNARY(cos)
  NFCUOP_POLY_UNARY(tanh)
  NFCUOP_POLY_UNARY(sigmoid)
  NFCUOP_POLY_UNARY(relu)
  NFCUOP_POLY_UNARY(square)
  NFCUOP_POLY_UNARY(reciprocal)
#undef NFCUOP_POLY_UNARY
#define NFCUOP_POLY_REDUCE(NAME, MEMBER)                                                                              \
  b.method_fn(NAME, [](const NumPy& n, const Value& a, const Value& axis, const Value& keep) {                        \
    return as_tensor(*n.s, a).MEMBER(axes_of(axis), truthy(keep));                                                    \
  }, 1);
  NFCUOP_POLY_REDUCE("sum", sum)
  NFCUOP_POLY_REDUCE("mean", mean)
  NFCUOP_POLY_REDUCE("max", max)
  NFCUOP_POLY_REDUCE("min", min)
  NFCUOP_POLY_REDUCE("var", var)
  NFCUOP_POLY_REDUCE("std", stddev)
#undef NFCUOP_POLY_REDUCE
  b.method_fn("reshape", [](const NumPy& n, const Value& a, const Value& shape) { return as_tensor(*n.s, a).reshape(shape_of(shape)); });
  b.method_fn("transpose", [](const NumPy& n, const Value& a, const Value& perm) {
    Tensor t = as_tensor(*n.s, a);
    return perm.is_nil() ? t.transpose() : t.transpose(axes_of(perm));
  }, 1);
  b.method_fn("expand_dims", [](const NumPy& n, const Value& a, const Value& axis) { return as_tensor(*n.s, a).expand_dims(int_of(axis, "axis")); });
  b.method_fn("squeeze", [](const NumPy& n, const Value& a, const Value& axis) {
    Tensor t = as_tensor(*n.s, a);
    return axis.is_nil() ? t.squeeze() : t.squeeze(int_of(axis, "axis"));
  }, 1);
  b.method_fn("flip", [](const NumPy& n, const Value& a, const Value& axis) { return as_tensor(*n.s, a).flip(axis.is_nil() ? 0 : int_of(axis, "axis")); }, 1);
  b.method_fn("broadcast_to", [](const NumPy& n, const Value& a, const Value& shape) { return as_tensor(*n.s, a).broadcast_to(shape_of(shape)); });
}

}  // namespace

void bind_numpy(nfcpoly::Context& ctx, np::Session& session, const std::string& name) {
  def_tensor(ctx.def_class<Tensor>("Tensor"));
  def_numpy(ctx.def_class<NumPy>("NumPy"));
  NumPy facade;
  facade.s = &session;
  // not std::make_shared: on the qbe back end its function-local static (_Sp_make_shared_tag::_S_ti) is emitted as a strong symbol
  // in every translation unit that uses it, and nfcpoly_go.cpp uses it too (docs/notes/multi-tu.md)
  facade.st = std::shared_ptr<State>(new State());
  ctx.set(name, facade);
}

}  // namespace poly
}  // namespace nfcuop

#endif  // __has_include("nfcpoly.hpp")
