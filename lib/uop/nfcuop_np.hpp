// nfcuop::np: the numpy-like user API. Operations build a high-level ONNX-style graph (nfcuop_hir.hpp); the graph can be
// exported to an ONNX file before anything is lowered, and evaluating a tensor lowers the graph to UOps
// (nfcuop_ut.hpp) and runs the reference interpreter. Tensors are lazy.
//
//   nfcuop::np::Session np;
//   auto a = np.array({1, 2, 3, 4, 5, 6}, {2, 3});          // float32, shape (2, 3)
//   auto b = np.arange(3);                                   // [0., 1., 2.]
//   auto c = (a * 2.0 + b).sum(/*axis=*/1);                  // broadcasting, like numpy
//   std::cout << relu(matmul(a, a.T())).str() << "\n";       // [[14., 32.], [32., 77.]]
//   auto x = np.placeholder("x", {2, 3});                    // an input bound when realized
//   auto y = softmax(matmul(x, w) + bias);                   // w, bias: tensors made with np.array
//   Array r = np.eval(y, {{"x", some_array}});
//   np.save_onnx("model.onnx", {{"y", y}});                  // the graph as ONNX, nothing lowered
//
// How close this is to numpy, and where it differs on purpose, is in docs/notes/uop.md ("numpy compatibility").
// In short: the dtypes are bool, int32, int64, float32, float64; promotion is the larger of the two in that order
// (int64 + float32 is float32); `%` and floor_divide follow numpy but only for ints; there are no empty tensors
// (every dimension is at least 1), no views or in-place updates, no random numbers, and shapes are static.
//
// Default dtypes are 32-bit and configurable per Session, the way numpy takes dtype= per call and the way numpy's own
// defaults are int64/float64: `np.default_float` (float32) is the dtype of array(), zeros(), arange(0.5, ...), linspace()
// and of the result of `/`, mean() and the float functions on integer tensors; `np.default_int` (int32) is the dtype of
// arange(5), full(shape, 7), of sum() of bool and (at least) of integer sums, and of bool arithmetic. Setting them to
// float64 and int64 gives numpy's defaults. A dtype argument on any constructor overrides them, and a Python-style scalar
// next to a tensor takes the tensor's dtype (a float scalar next to an int tensor takes default_float).
#pragma once
#include <initializer_list>
#include <map>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "nfcuop.hpp"
#include "nfcuop_hir.hpp"
#include "nfcuop_ut.hpp"

namespace nfcuop {
namespace np {

class Session;
using Axes = std::vector<int64_t>;  // negative axes count from the end, like numpy
constexpr int64_t None = INT64_MIN;  // an omitted slice bound: t.slice(0, None, None, -1) is t[::-1]

class Tensor {
 public:
  Tensor() {}
  Tensor(Session* s, int id) : s_(s), id_(id) {}
  bool valid() const { return s_ != nullptr && id_ >= 0; }
  int id() const { return id_; }  // the value in the Session's hir::Graph
  Session& session() const { return *s_; }

  const Shape& shape() const;
  int64_t ndim() const { return static_cast<int64_t>(shape().size()); }
  int64_t size() const { return numel(shape()); }
  DType dtype() const;

  // shape
  Tensor reshape(Shape shape) const;  // one dimension may be -1
  Tensor transpose() const;           // reverses the axes
  Tensor transpose(const Axes& perm) const;
  Tensor T() const { return transpose(); }
  Tensor swapaxes(int64_t a, int64_t b) const;
  Tensor flatten() const { return reshape({size()}); }
  Tensor ravel() const { return flatten(); }
  Tensor squeeze() const;  // all axes of size 1
  Tensor squeeze(int64_t axis) const;
  Tensor expand_dims(int64_t axis) const;
  Tensor broadcast_to(const Shape& shape) const;
  Tensor astype(DType d) const;
  // a[start:stop:step] along one axis (None omits a bound); the result must keep at least one element
  Tensor slice(int64_t axis, int64_t start, int64_t stop, int64_t step = 1) const;
  Tensor at(int64_t index, int64_t axis = 0) const;  // a[index] along `axis`, dropping that axis
  Tensor flip(int64_t axis = 0) const;

  // reductions: no axis means all of them; the result drops the reduced axes unless keepdims
  Tensor sum(const Axes& axes = {}, bool keepdims = false) const;
  Tensor sum(int64_t axis, bool keepdims = false) const { return sum(Axes{axis}, keepdims); }
  Tensor mean(const Axes& axes = {}, bool keepdims = false) const;
  Tensor mean(int64_t axis, bool keepdims = false) const { return mean(Axes{axis}, keepdims); }
  Tensor max(const Axes& axes = {}, bool keepdims = false) const;
  Tensor max(int64_t axis, bool keepdims = false) const { return max(Axes{axis}, keepdims); }
  Tensor min(const Axes& axes = {}, bool keepdims = false) const;
  Tensor min(int64_t axis, bool keepdims = false) const { return min(Axes{axis}, keepdims); }
  // population variance (correction 0); otherwise the sum of squared deviations divided by (n - correction), as the standard's `correction`
  Tensor var(const Axes& axes = {}, bool keepdims = false, double correction = 0) const;
  Tensor stddev(const Axes& axes = {}, bool keepdims = false, double correction = 0) const;
  Tensor prod(const Axes& axes = {}, bool keepdims = false) const;   // ReduceProd; bool and narrow ints give default_int, as sum
  Tensor prod(int64_t axis, bool keepdims = false) const { return prod(Axes{axis}, keepdims); }
  // Running sum along `axis` (ONNX CumSum); axis None flattens first, like numpy. bool and narrow ints give default_int.
  Tensor cumsum(int64_t axis = None) const;
  // Index of the first maximum (minimum) along `axis` (ONNX ArgMax/ArgMin, an int32 by default: numpy's intp is int64 and
  // default_int is int32). None flattens first. A NaN wins, as in numpy; bool operands are read as ints.
  Tensor argmax(int64_t axis = None, bool keepdims = false) const;
  Tensor argmin(int64_t axis = None, bool keepdims = false) const;

  // elementwise
  Tensor operator-() const;
  Tensor abs() const;
  Tensor sqrt() const;
  Tensor exp() const;
  Tensor log() const;
  Tensor sin() const;
  Tensor cos() const;
  Tensor tanh() const;
  // The Array API's elementwise functions (docs/notes/array-api.md): floats out. An integer input is converted to the default float,
  // as for sin; round keeps an integer tensor as it is (numpy does), and rounds half to even otherwise.
  Tensor acos() const;
  Tensor acosh() const;
  Tensor asin() const;
  Tensor asinh() const;
  Tensor atan() const;
  Tensor atanh() const;
  Tensor cosh() const;
  Tensor sinh() const;
  Tensor tan() const;
  Tensor expm1() const;
  Tensor log1p() const;
  Tensor log2() const;
  Tensor log10() const;
  Tensor round() const;
  Tensor sigmoid() const;
  Tensor relu() const;
  Tensor square() const;
  Tensor reciprocal() const;
  Tensor softmax(int64_t axis = -1) const;
  Tensor log_softmax(int64_t axis = -1) const;
  Tensor clip(double lo, double hi) const;
  Tensor floor() const;   // ONNX Floor; an integer tensor is returned as it is (numpy keeps the integer dtype); bool gives default_float
  Tensor ceil() const;    // ONNX Ceil; likewise
  Tensor isnan() const;   // Bool; all false for integers and bools
  Tensor isinf() const;   // Bool; all false for integers and bools

  // realization (lowers the graph to UOps and evaluates it)
  Array numpy() const;
  std::vector<double> tolist() const;  // flattened, row-major
  double item() const;                 // the only element
  std::string str() const;             // "[[1., 2.], [3., 4.]]"
  std::string dump() const;            // the Session's graph, as hir::Graph::str
  std::string dump_uops() const;       // the UOp graph this tensor lowers to, as nfcuop::dump

 private:
  Session* s_ = nullptr;
  int id_ = -1;
};

// Owns the graph and the data of tensors made from arrays. Not copyable; tensors must not outlive it.
class Session {
 public:
  Session() : lowerer_(hir_, ut_) {}
  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  // dtypes left out: default_float for array, scalar, zeros, ones, linspace, eye, placeholder and for a float full/arange;
  // default_int for an integer full/arange (like numpy, which looks at the Python type of the value)
  DType default_float = DType::Float32;
  DType default_int = DType::Int32;

  Tensor array(const std::vector<double>& v, std::optional<DType> d = {});  // 1-D
  Tensor array(const std::vector<double>& v, const Shape& shape, std::optional<DType> d = {});
  Tensor array2d(const std::vector<std::vector<double>>& rows, std::optional<DType> d = {});
  Tensor from(const Array& a);
  Tensor scalar(double v, std::optional<DType> d = {});
  Tensor zeros(const Shape& shape, std::optional<DType> d = {});
  Tensor ones(const Shape& shape, std::optional<DType> d = {});
  template <class T, std::enable_if_t<std::is_arithmetic<T>::value, int> = 0>
  Tensor full(const Shape& shape, T v, std::optional<DType> d = {}) {
    return full_impl(shape, static_cast<double>(v), d ? *d : (std::is_integral<T>::value ? default_int : default_float));
  }
  Tensor arange(int64_t n, std::optional<DType> d = {});  // 0, 1, ..., n-1; default_int
  // arange(start, stop, step): default_int when start, stop and step are all integers, default_float otherwise
  template <class A, class B, class C = int,
            std::enable_if_t<std::is_arithmetic<A>::value && std::is_arithmetic<B>::value && std::is_arithmetic<C>::value, int> = 0>
  Tensor arange(A start, B stop, C step = 1, std::optional<DType> d = {}) {
    const bool ints = std::is_integral<A>::value && std::is_integral<B>::value && std::is_integral<C>::value;
    return arange_impl(static_cast<double>(start), static_cast<double>(stop), static_cast<double>(step), d ? *d : (ints ? default_int : default_float));
  }
  Tensor linspace(double start, double stop, int64_t num, std::optional<DType> d = {}, bool endpoint = true);  // both ends included unless !endpoint
  Tensor eye(int64_t n, std::optional<DType> d = {});
  Tensor eye(int64_t rows, int64_t cols, int64_t k = 0, std::optional<DType> d = {});  // ones on the k-th diagonal (k > 0 above the main one)
  // the values are unspecified in the standard; here they are zeros
  Tensor empty(const Shape& shape, std::optional<DType> d = {}) { return zeros(shape, d); }
  Tensor placeholder(const std::string& name, const Shape& shape, std::optional<DType> d = {});

  // The value of `t`; `feeds` binds the placeholders it depends on. Runs symbolic() on the UOps first when optimize is true.
  Array eval(const Tensor& t, const std::map<std::string, Array>& feeds = {});
  // Several values at once: one lowering, and with the C backend one compiled program.
  std::vector<Array> eval_all(const std::vector<Tensor>& ts, const std::map<std::string, Array>& feeds = {});
  bool optimize = true;
  // The reference interpreter, compiled C (nfcuop_cgen.hpp; `cc` is the compiler command, empty: $NFCUOP_CC, else cc), or
  // ONNX Runtime on the graph (Backend::Ort, nfcuop_ort.hpp; the library comes from $NFCUOP_ORT_LIB), or tinygrad (Backend::Tinygrad,
  // nfcuop_tinygrad.hpp; the Python executable from $NFCUOP_TINYGRAD_PYTHON).
  ut::Session::Backend backend = ut::Session::Backend::Interpreter;
  std::string cc;

  // The ONNX ModelProto (opset 18) computing the named tensors from the placeholders, as bytes; nothing is lowered.
  // Each output gets an Identity node carrying its name. save_onnx writes the bytes to a file.
  std::string to_onnx(const std::vector<std::pair<std::string, Tensor>>& outputs, const std::string& graph_name = "nfcuop");
  void save_onnx(const std::string& path, const std::vector<std::pair<std::string, Tensor>>& outputs);

  hir::Graph& graph() { return hir_; }
  ut::Tensor lower(const Tensor& t) { return lowerer_.get(t.id()); }  // the UOp tensor of `t`
  ut::Session& uop_session() { return ut_; }

  // used by the operators; a constant of this content, shared
  int constant(const Array& a);
  Tensor full_impl(const Shape& shape, double v, DType d);
  Tensor arange_impl(double start, double stop, double step, DType d);

 private:
  hir::Graph hir_;
  ut::Session ut_;
  hir::Lowerer lowerer_;
  std::map<std::string, int> consts_;
  int next_tensor_ = 0;
};

// ---- functions ----
Tensor where(const Tensor& cond, const Tensor& a, const Tensor& b);
Tensor maximum(const Tensor& a, const Tensor& b);
Tensor minimum(const Tensor& a, const Tensor& b);
Tensor floor_divide(const Tensor& a, const Tensor& b);  // ints only; rounds toward minus infinity like numpy
Tensor remainder(const Tensor& a, const Tensor& b);     // ints only; the sign of the divisor like numpy
Tensor matmul(const Tensor& a, const Tensor& b);        // 1-D and N-D like numpy, batch dimensions broadcast
inline Tensor dot(const Tensor& a, const Tensor& b) { return matmul(a, b); }  // for 1-D and 2-D operands
Tensor logical_not(const Tensor& a);
// atan2(y, x) for floats (the promoted dtype; an integer pair gives the default float). Operands broadcast, as the operators do.
Tensor atan2(const Tensor& y, const Tensor& x);
// log(exp(a) + exp(b)) without overflow: computed as max + log1p(exp(-|a - b|)), with the infinite cases handled (-inf and -inf give
// -inf, +inf and anything give +inf). Floats. Built from Log1p, so a graph that has it cannot be exported to ONNX.
Tensor logaddexp(const Tensor& a, const Tensor& b);
// a << b and a >> b for integers (numpy's bitwise_left_shift and bitwise_right_shift; the operators below are the same functions): a count
// below 0 or at least the width gives 0, and a right shift of a negative value gives -1. Bool and floats are an error.
Tensor bitwise_left_shift(const Tensor& a, const Tensor& b);
Tensor bitwise_right_shift(const Tensor& a, const Tensor& b);
// a ** b (C++ has no ** operator). The dtype is the promoted one, and a Python-style scalar is weak as in the operators. Floats follow
// C99 pow, the values numpy gives; integers wrap, and a negative integer exponent is not an error (see docs/notes/uop.md).
Tensor pow(const Tensor& a, const Tensor& b);
Tensor concatenate(const std::vector<Tensor>& ts, int64_t axis = 0);
Tensor stack(const std::vector<Tensor>& ts, int64_t axis = 0);
// numpy's tile: `reps` has one entry per dimension; a shorter reps gets leading 1s, and a shorter shape gets leading 1s (the
// result has max(ndim, reps) dimensions). Every repetition is at least 1 (numpy's 0 would give an empty tensor).
Tensor tile(const Tensor& a, const Shape& reps);
inline Tensor tile(const Tensor& a, int64_t reps) { return tile(a, Shape{reps}); }
// numpy's take: the elements of `a` at `indices` along `axis` (ONNX Gather); axis None takes from the flattened array, like numpy.
// The indices must be integers (a Tensor of them, e.g. np.array({0, 2}, DType::Int32)); negative ones count from the end.
// Constant indices are checked against the axis (an error if out of range); runtime ones are not (they select nothing, a -0.0).
Tensor take(const Tensor& a, const Tensor& indices, int64_t axis = None);
inline Tensor relu(const Tensor& a) { return a.relu(); }
inline Tensor exp(const Tensor& a) { return a.exp(); }
inline Tensor log(const Tensor& a) { return a.log(); }
inline Tensor sqrt(const Tensor& a) { return a.sqrt(); }
inline Tensor tanh(const Tensor& a) { return a.tanh(); }
inline Tensor abs(const Tensor& a) { return a.abs(); }
inline Tensor acos(const Tensor& a) { return a.acos(); }
inline Tensor acosh(const Tensor& a) { return a.acosh(); }
inline Tensor asin(const Tensor& a) { return a.asin(); }
inline Tensor asinh(const Tensor& a) { return a.asinh(); }
inline Tensor atan(const Tensor& a) { return a.atan(); }
inline Tensor atanh(const Tensor& a) { return a.atanh(); }
inline Tensor cosh(const Tensor& a) { return a.cosh(); }
inline Tensor sinh(const Tensor& a) { return a.sinh(); }
inline Tensor tan(const Tensor& a) { return a.tan(); }
inline Tensor expm1(const Tensor& a) { return a.expm1(); }
inline Tensor log1p(const Tensor& a) { return a.log1p(); }
inline Tensor log2(const Tensor& a) { return a.log2(); }
inline Tensor log10(const Tensor& a) { return a.log10(); }
inline Tensor round(const Tensor& a) { return a.round(); }
inline Tensor softmax(const Tensor& a, int64_t axis = -1) { return a.softmax(axis); }

// ---- the Python Array API standard, and the numpy functions it is compared with (docs/notes/array-api.md has the full table) ----
// Each is built from the operators above, so it is in the ONNX file as ordinary nodes. Data-dependent shapes (nonzero, unique)
// are not supported. The sorting functions are quadratic in the length of the sorted axis, as cumsum is.
Tensor operator+(const Tensor& a);  // unary plus (positive): not for bool
Tensor operator~(const Tensor& a);  // bitwise invert: logical not for bool, -x - 1 for integers
Tensor positive(const Tensor& a);
Tensor add(const Tensor& a, const Tensor& b);
Tensor subtract(const Tensor& a, const Tensor& b);
Tensor multiply(const Tensor& a, const Tensor& b);
Tensor divide(const Tensor& a, const Tensor& b);  // true division
Tensor negative(const Tensor& a);
Tensor equal(const Tensor& a, const Tensor& b);
Tensor not_equal(const Tensor& a, const Tensor& b);
Tensor greater(const Tensor& a, const Tensor& b);
Tensor greater_equal(const Tensor& a, const Tensor& b);
Tensor less(const Tensor& a, const Tensor& b);
Tensor less_equal(const Tensor& a, const Tensor& b);
Tensor logical_and(const Tensor& a, const Tensor& b);  // bool operands only, as in the standard
Tensor logical_or(const Tensor& a, const Tensor& b);
Tensor logical_xor(const Tensor& a, const Tensor& b);
Tensor bitwise_and(const Tensor& a, const Tensor& b);  // integers and bool
Tensor bitwise_or(const Tensor& a, const Tensor& b);
Tensor bitwise_xor(const Tensor& a, const Tensor& b);
Tensor bitwise_invert(const Tensor& a);
Tensor isfinite(const Tensor& a);  // bool and integers: all true; floats: not NaN and not infinite
Tensor trunc(const Tensor& a);     // towards zero; integers as they are; not for bool
Tensor sign(const Tensor& a);      // -1, 0 or 1; NaN stays NaN; -0 gives +0; not for bool

// creation
Tensor asarray(const Tensor& a, std::optional<DType> d = {});       // the tensor itself, or astype(d)
Tensor asarray(Session& s, const Array& a, std::optional<DType> d = {});
Tensor zeros_like(const Tensor& a, std::optional<DType> d = {});
Tensor ones_like(const Tensor& a, std::optional<DType> d = {});
Tensor empty_like(const Tensor& a, std::optional<DType> d = {});   // zeros, as Session::empty
Tensor full_like(const Tensor& a, double v, std::optional<DType> d = {});
Tensor tril(const Tensor& a, int64_t k = 0);  // the last two axes: the entries with j - i <= k kept, the others zero
Tensor triu(const Tensor& a, int64_t k = 0);  // j - i >= k kept
std::vector<Tensor> meshgrid(const std::vector<Tensor>& xs, bool xy = true);  // one-dimensional inputs; indexing "xy" (default) or "ij"
Tensor copy(const Tensor& a);  // numpy's copy: the same tensor, since tensors are never changed in place

// data types
DType result_type(DType a, DType b);                  // the promotion of the operators
DType result_type(const std::vector<Tensor>& ts);
// numpy's safe casting over the five dtypes (bool to anything; int32 to int64 or float64; int64 to float64; float32 to float64)
bool can_cast(DType from, DType to);
struct FInfo { DType dtype; int bits; double eps, max, min, smallest_normal; };
struct IInfo { DType dtype; int bits; int64_t min, max; };
FInfo finfo(DType d);  // float32 or float64
IInfo iinfo(DType d);  // int32 or int64
// kinds: "bool", "signed integer", "integral", "real floating", "numeric"; "unsigned integer" and "complex floating" are never true here
bool isdtype(DType d, const std::string& kind);
bool isdtype(DType d, const std::vector<std::string>& kinds);
std::vector<Tensor> broadcast_arrays(const std::vector<Tensor>& ts);

// searching, sorting, sets
// searchsorted: the insertion index of each value into the sorted 1-D `sorted`; side left (default) or right; NaN sorts last
Tensor searchsorted(const Tensor& sorted, const Tensor& v, bool right = false);
Tensor count_nonzero(const Tensor& a, const Axes& axes = {}, bool keepdims = false);  // numpy (not in the standard)
// Stable sort along `axis`; descending keeps equal elements in their order too. NaN is last (first when descending).
// -0 and +0 are equal here. The standard's `stable=False` is not needed: this is always stable.
Tensor sort(const Tensor& a, int64_t axis = -1, bool descending = false);
Tensor argsort(const Tensor& a, int64_t axis = -1, bool descending = false);  // the default int indices
// numpy's take_along_axis: indices of the same rank; the non-axis dimensions broadcast; negative indices count from the end
Tensor take_along_axis(const Tensor& a, const Tensor& indices, int64_t axis);

// statistics and utility
// axis None flattens first (numpy); include_initial prepends the identity (0 or 1) along the axis, as the standard
Tensor cumulative_sum(const Tensor& a, int64_t axis = None, bool include_initial = false);
Tensor cumulative_prod(const Tensor& a, int64_t axis = None, bool include_initial = false);
Tensor cumprod(const Tensor& a, int64_t axis = None);
Tensor all(const Tensor& a, const Axes& axes = {}, bool keepdims = false);  // bool result
Tensor any(const Tensor& a, const Axes& axes = {}, bool keepdims = false);

// manipulation
Tensor concat(const std::vector<Tensor>& ts, int64_t axis = 0);
Tensor moveaxis(const Tensor& a, int64_t source, int64_t destination);
Tensor permute_dims(const Tensor& a, const Axes& perm);
// each element repeated `repeats` times along `axis`; axis None flattens first
Tensor repeat(const Tensor& a, int64_t repeats, int64_t axis = None);
// circular shift; axis None rolls the flattened array and restores the shape
Tensor roll(const Tensor& a, int64_t shift, int64_t axis = None);
Tensor roll(const Tensor& a, const Axes& shifts, const Axes& axes);
std::vector<Tensor> unstack(const Tensor& a, int64_t axis = 0);

// linear algebra
Tensor matrix_transpose(const Tensor& a);  // the last two axes
Tensor vecdot(const Tensor& a, const Tensor& b, int64_t axis = -1);  // sum of a * b along `axis` (real values: no conjugate)
Tensor tensordot(const Tensor& a, const Tensor& b, int64_t n = 2);  // the last n axes of a with the first n of b
Tensor tensordot(const Tensor& a, const Tensor& b, const Axes& axes_a, const Axes& axes_b);
// numpy's einsum: "ij,jk->ik", or without "->" the indices that occur once, in alphabetical order. No ellipsis, and no index
// repeated within one operand (a diagonal). The product of the operands is formed in full before the sums, so its size is
// the product of all the index sizes.
Tensor einsum(const std::string& subscripts, const std::vector<Tensor>& ops);

// Reverse-mode derivatives (nfcuop_grad.hpp, docs/notes/uop-autodiff.md): d loss / d wrt[k], one tensor per `wrt`, with its shape
// and dtype. `loss` is a float scalar (e.g. `.sum()` or `.mean()` of something); each `wrt` is a float placeholder, a constant made
// with array() or any other tensor. The result is more nodes of the same graph: evaluate it with eval/eval_all, or export it
// with to_onnx next to the loss. Constants with equal content (up to 64 elements) are one tensor, so two equal arrays are one `wrt`.
std::vector<Tensor> grad(const Tensor& loss, const std::vector<Tensor>& wrt);
Tensor grad(const Tensor& loss, const Tensor& wrt);

Tensor operator+(const Tensor& a, const Tensor& b);
Tensor operator-(const Tensor& a, const Tensor& b);
Tensor operator*(const Tensor& a, const Tensor& b);
Tensor operator/(const Tensor& a, const Tensor& b);  // true division, float
Tensor operator%(const Tensor& a, const Tensor& b);  // remainder
Tensor operator<(const Tensor& a, const Tensor& b);
Tensor operator>(const Tensor& a, const Tensor& b);
Tensor operator<=(const Tensor& a, const Tensor& b);
Tensor operator>=(const Tensor& a, const Tensor& b);
Tensor operator==(const Tensor& a, const Tensor& b);  // elementwise, like numpy
Tensor operator!=(const Tensor& a, const Tensor& b);
Tensor operator&(const Tensor& a, const Tensor& b);
Tensor operator|(const Tensor& a, const Tensor& b);
Tensor operator^(const Tensor& a, const Tensor& b);
Tensor operator<<(const Tensor& a, const Tensor& b);  // integers only, as bitwise_left_shift
Tensor operator>>(const Tensor& a, const Tensor& b);  // integers only, as bitwise_right_shift

namespace detail {
Tensor lift(const Tensor& like, double v, bool integral);  // a scalar tensor for `v` next to `like`
template <class T>
using IsNum = std::enable_if_t<std::is_arithmetic<T>::value, int>;
}  // namespace detail

#define NFCUOP_NP_SCALAR_OP(OP)                                                                              \
  template <class T, detail::IsNum<T> = 0>                                                                   \
  Tensor operator OP(const Tensor& a, T v) { return a OP detail::lift(a, static_cast<double>(v), std::is_integral<T>::value); } \
  template <class T, detail::IsNum<T> = 0>                                                                   \
  Tensor operator OP(T v, const Tensor& b) { return detail::lift(b, static_cast<double>(v), std::is_integral<T>::value) OP b; }
NFCUOP_NP_SCALAR_OP(+)
NFCUOP_NP_SCALAR_OP(-)
NFCUOP_NP_SCALAR_OP(*)
NFCUOP_NP_SCALAR_OP(/)
NFCUOP_NP_SCALAR_OP(%)
NFCUOP_NP_SCALAR_OP(<)
NFCUOP_NP_SCALAR_OP(>)
NFCUOP_NP_SCALAR_OP(<=)
NFCUOP_NP_SCALAR_OP(>=)
NFCUOP_NP_SCALAR_OP(==)
NFCUOP_NP_SCALAR_OP(!=)
#undef NFCUOP_NP_SCALAR_OP
template <class T, detail::IsNum<T> = 0>
Tensor pow(const Tensor& a, T v) { return pow(a, detail::lift(a, static_cast<double>(v), std::is_integral<T>::value)); }
template <class T, detail::IsNum<T> = 0>
Tensor pow(T v, const Tensor& b) { return pow(detail::lift(b, static_cast<double>(v), std::is_integral<T>::value), b); }

}  // namespace np
}  // namespace nfcuop
