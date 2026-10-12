// nfcuop::np: a numpy-like Tensor API over the UOp graph. Tensors are lazy: operations build nodes of a
// Graph, and numpy()/item()/str() realize a tensor with the reference interpreter (after symbolic()).
//
//   nfcuop::np::Session np;
//   auto a = np.array({1, 2, 3, 4, 5, 6}, {2, 3});          // float32, shape (2, 3)
//   auto b = np.arange(3);                                   // [0., 1., 2.]
//   auto c = (a * 2.0 + b).sum(/*axis=*/1);                  // broadcasting, like numpy
//   std::cout << relu(matmul(a, a.T())).str() << "\n";       // [[14., 32.], [32., 77.]]
//   auto x = np.placeholder("x", {2, 3});                    // an input bound when realized
//   Array r = np.eval(x * x, {{"x", some_array}});
//
// Differences from numpy, all deliberate: the dtype set is bool, int32, int64, float32, float64; promotion is the
// larger of the two in that order (int64 + float32 is float32, an int scalar keeps an int tensor's dtype, a
// float scalar makes an int tensor float32); `/` and the float functions of an int tensor compute in float32;
// `%` and floor_divide follow numpy (the sign of the divisor) but only for ints; there is no indexing, slicing,
// concatenation or random numbers yet (they need Shrink/Pad ops, a later stage). See docs/notes/uop.md.
#pragma once
#include <initializer_list>
#include <map>
#include <string>
#include <type_traits>
#include <vector>

#include "nfcuop.hpp"

namespace nfcuop {
namespace np {

class Session;
using Axes = std::vector<int64_t>;  // negative axes count from the end, like numpy

class Tensor {
 public:
  Tensor() {}
  Tensor(Session* s, const UOp* u) : s_(s), u_(u) {}
  bool valid() const { return u_ != nullptr; }
  const UOp* uop() const { return u_; }
  Session& session() const { return *s_; }

  const Shape& shape() const { return u_->shape; }
  int64_t ndim() const { return static_cast<int64_t>(u_->shape.size()); }
  int64_t size() const { return numel(u_->shape); }
  DType dtype() const { return u_->dtype; }

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

  // reductions: no axis means all of them; the result drops the reduced axes unless keepdims
  Tensor sum(const Axes& axes = {}, bool keepdims = false) const;
  Tensor sum(int64_t axis, bool keepdims = false) const { return sum(Axes{axis}, keepdims); }
  Tensor mean(const Axes& axes = {}, bool keepdims = false) const;
  Tensor mean(int64_t axis, bool keepdims = false) const { return mean(Axes{axis}, keepdims); }
  Tensor max(const Axes& axes = {}, bool keepdims = false) const;
  Tensor max(int64_t axis, bool keepdims = false) const { return max(Axes{axis}, keepdims); }
  Tensor min(const Axes& axes = {}, bool keepdims = false) const;
  Tensor min(int64_t axis, bool keepdims = false) const { return min(Axes{axis}, keepdims); }
  Tensor var(const Axes& axes = {}, bool keepdims = false) const;  // population variance (ddof = 0)
  Tensor stddev(const Axes& axes = {}, bool keepdims = false) const;

  // elementwise
  Tensor operator-() const;
  Tensor abs() const;
  Tensor sqrt() const;
  Tensor exp() const;
  Tensor log() const;
  Tensor sin() const;
  Tensor cos() const;
  Tensor tanh() const;
  Tensor sigmoid() const;
  Tensor relu() const;
  Tensor square() const;
  Tensor reciprocal() const;
  Tensor softmax(int64_t axis = -1) const;
  Tensor log_softmax(int64_t axis = -1) const;
  Tensor clip(double lo, double hi) const;

  // realization (evaluates the graph)
  Array numpy() const;
  std::vector<double> tolist() const;  // flattened, row-major
  double item() const;                 // the only element
  std::string str() const;             // "[[1., 2.], [3., 4.]]"
  std::string dump() const;            // the UOp graph, as nfcuop::dump

 private:
  Session* s_ = nullptr;
  const UOp* u_ = nullptr;
};

// Owns the graph and the data of tensors made from arrays. Not copyable; tensors must not outlive it.
class Session {
 public:
  Session() {}
  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;
  Graph& graph() { return g_; }

  Tensor array(const std::vector<double>& v, DType d = DType::Float32);  // 1-D
  Tensor array(const std::vector<double>& v, const Shape& shape, DType d = DType::Float32);
  Tensor array2d(const std::vector<std::vector<double>>& rows, DType d = DType::Float32);
  Tensor from(const Array& a);
  Tensor scalar(double v, DType d = DType::Float32);
  Tensor zeros(const Shape& shape, DType d = DType::Float32);
  Tensor ones(const Shape& shape, DType d = DType::Float32);
  Tensor full(const Shape& shape, double v, DType d = DType::Float32);
  Tensor arange(int64_t n, DType d = DType::Float32);
  Tensor arange(double start, double stop, double step = 1, DType d = DType::Float32);
  Tensor linspace(double start, double stop, int64_t num, DType d = DType::Float32);  // both ends included
  Tensor eye(int64_t n, DType d = DType::Float32);
  Tensor placeholder(const std::string& name, const Shape& shape, DType d = DType::Float32);

  // The value of `t`; `feeds` binds the placeholders it depends on. Runs symbolic() first when optimize is true.
  Array eval(const Tensor& t, const std::map<std::string, Array>& feeds = {});
  bool optimize = true;

 private:
  Graph g_;
  std::map<std::string, Array> buffers_;
  int next_buf_ = 0;
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
inline Tensor relu(const Tensor& a) { return a.relu(); }
inline Tensor exp(const Tensor& a) { return a.exp(); }
inline Tensor log(const Tensor& a) { return a.log(); }
inline Tensor sqrt(const Tensor& a) { return a.sqrt(); }
inline Tensor tanh(const Tensor& a) { return a.tanh(); }
inline Tensor abs(const Tensor& a) { return a.abs(); }

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

}  // namespace np
}  // namespace nfcuop
