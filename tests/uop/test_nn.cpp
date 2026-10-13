// The forward operators Gemm, Gather, Erf, Conv, MaxPool, AveragePool, BatchNormalization, InstanceNormalization and
// LayerNormalization of hir (nfcuop_hir.cpp: shape inference; nfcuop_lower.cpp: lowering to UOps). Each operator has
//  (a) shape inference and the refusals of unsupported attribute combinations,
//  (b) numerical checks: the lowered value (UOp interpreter) against a direct reference computed here (exact formulas for Gemm,
//      Gather, Erf; naive loops over the windows for Conv and pooling; the formulas for the normalizations),
//  (c) an export/import round trip (to_onnx -> from_onnx -> to_onnx gives the same bytes, and the same values),
//  (d) models for onnx.checker and onnxruntime, written to argv[1] for tests/uop/onnx_check.py.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "nfcuop_hir.hpp"

using namespace nfcuop;

static int checks = 0, failed = 0;
#define CHECK(cond)                                                                      \
  do {                                                                                   \
    checks++;                                                                            \
    if (!(cond)) { failed++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
// the statement must throw an Error whose message contains `frag`
#define CHECK_ERR(expr, frag)                                                                                      \
  do {                                                                                                             \
    checks++;                                                                                                      \
    std::string msg_;                                                                                              \
    bool threw_ = false;                                                                                           \
    try { (void)(expr); } catch (const Error& e) { threw_ = true; msg_ = e.what(); }                               \
    if (!threw_ || msg_.find(frag) == std::string::npos) {                                                         \
      failed++;                                                                                                    \
      std::printf("FAIL %s:%d: %s: %s, expected an error containing \"%s\"\n", __FILE__, __LINE__, #expr,          \
                  threw_ ? ("error \"" + msg_ + "\"").c_str() : "no error", frag);                                 \
    }                                                                                                              \
  } while (0)

using V = std::vector<double>;
using hir::Attribute;
static const DType f32 = DType::Float32, f64 = DType::Float64, i32 = DType::Int32, i64 = DType::Int64;
static Array arr(DType d, const Shape& s, const V& v) { return Array::from_doubles(d, s, v); }
static V vals(const Array& a) { V v; for (const Scalar& s : a.data) v.push_back(s.as_double()); return v; }
static int64_t prod(const Shape& s) { return numel(s); }
// |a - b| <= tol * (1 + |b|), NaN equal to NaN
static bool near(const V& a, const V& b, double tol) {
  if (a.size() != b.size()) return false;
  for (size_t k = 0; k < a.size(); k++) {
    if (std::isnan(a[k]) && std::isnan(b[k])) continue;
    if (!(std::fabs(a[k] - b[k]) <= tol * (1 + std::fabs(b[k])))) return false;
  }
  return true;
}
static V rand_vec(int64_t n, unsigned seed) {
  V v;
  uint64_t s = 0x9E3779B97F4A7C15ull * (seed + 1);
  for (int64_t k = 0; k < n; k++) {
    s = s * 6364136223846793005ull + 1442695040888963407ull;
    v.push_back(static_cast<double>(s >> 11) / 9007199254740992.0 * 2 - 1);
  }
  return v;
}
// Calls f with every index of `shape` in row-major order.
static void each_index(const Shape& shape, const std::function<void(const Shape&)>& f) {
  Shape at(shape.size(), 0);
  for (;;) {
    f(at);
    size_t k = shape.size();
    while (k > 0 && ++at[k - 1] == shape[k - 1]) at[--k] = 0;
    if (k == 0) return;
  }
}
static int64_t flat(const Shape& shape, const Shape& at) {
  int64_t f = 0;
  for (size_t k = 0; k < shape.size(); k++) f = f * shape[k] + at[k];
  return f;
}

// The value `id` of `g`, lowered to UOps and evaluated by the interpreter, with the graph's inputs fed from `feeds`.
static Array run(const hir::Graph& g, int id, const std::map<std::string, Array>& feeds) {
  ut::Session u;
  hir::Lowerer low(g, u);
  return u.eval(low.get(id), feeds);
}

// The same dtype, shape and bits (NaN equals NaN, -0.0 is not 0.0).
static bool same(const Array& a, const Array& b) {
  if (a.dtype != b.dtype || a.shape != b.shape || a.data.size() != b.data.size()) return false;
  for (size_t k = 0; k < a.data.size(); k++) {
    if (is_float(a.dtype)) {
      const double x = a.data[k].f, y = b.data[k].f;
      if (std::isnan(x) || std::isnan(y)) { if (!(std::isnan(x) && std::isnan(y))) return false; }
      else if (x != y || std::signbit(x) != std::signbit(y)) return false;
    } else if (a.data[k].i != b.data[k].i) {
      return false;
    }
  }
  return true;
}

// (c) export -> import -> export: the same bytes, and the values of the re-imported graph equal `want` bit for bit.
static void round_trip(const hir::Graph& g, const std::vector<int>& outs, const std::map<std::string, Array>& feeds, const std::vector<Array>& want) {
  std::string bytes = g.to_onnx(outs);
  std::vector<int> outs2;
  hir::Graph g2 = hir::Graph::from_onnx(bytes, &outs2);
  CHECK(outs2.size() == outs.size());
  CHECK(g2.to_onnx(outs2) == bytes);
  for (size_t k = 0; k < outs.size() && k < want.size(); k++) CHECK(same(run(g2, outs2[k], feeds), want[k]));
}

// ---- (a) shape inference and refusals ----

static void shapes() {
  hir::Graph g;
  int a = g.add_input("a", f32, {2, 3}), b = g.add_input("b", f32, {3, 4}), c = g.add_input("c", f32, {4});
  int at = g.add_input("at", f32, {3, 2}), i = g.add_input("i", i64, {5}), ii = g.add_input("ii", i32, {2, 2});
  int d3 = g.add_input("d3", f32, {2, 4, 5});
  // Gemm: op(A) (2,3) x op(B) (3,4) + C broadcast to (2,4)
  CHECK(g.value(g.add_node("Gemm", {a, b, c})).shape == (Shape{2, 4}));
  CHECK(g.value(g.add_node("Gemm", {at, b}, {Attribute::Int("transA", 1)})).shape == (Shape{2, 4}));
  CHECK_ERR(g.add_node("Gemm", {a, b}, {Attribute::Int("transB", 1)}), "do not align");
  CHECK_ERR(g.add_node("Gemm", {d3, b}), "must be 2-D");
  CHECK_ERR(g.add_node("Gemm", {a, a}), "do not align");
  CHECK_ERR(g.add_node("Gemm", {a, b, i}), "input dtypes differ");          // int64 C
  CHECK_ERR(g.add_node("Gemm", {ii, ii}), "float inputs");
  CHECK_ERR(g.add_node("Gemm", {a, b}, {Attribute::Int("transA", 2)}), "transA and transB");
  int bad_c = g.add_input("bad_c", f32, {3});
  CHECK_ERR(g.add_node("Gemm", {a, b, bad_c}), "does not broadcast");
  int row = g.add_input("row", f32, {1, 4});
  int col = g.add_input("col", f32, {2, 1});
  CHECK(g.value(g.add_node("Gemm", {a, b, row})).shape == (Shape{2, 4}));
  CHECK(g.value(g.add_node("Gemm", {a, b, col})).shape == (Shape{2, 4}));
  // Gather: output = data[:axis] + indices.shape + data[axis+1:]
  CHECK(g.value(g.add_node("Gather", {d3, i})).shape == (Shape{5, 4, 5}));                       // axis 0
  CHECK(g.value(g.add_node("Gather", {d3, ii}, {Attribute::Int("axis", 1)})).shape == (Shape{2, 2, 2, 5}));
  CHECK(g.value(g.add_node("Gather", {d3, ii}, {Attribute::Int("axis", -1)})).shape == (Shape{2, 4, 2, 2}));
  int scalar_ix = g.add_initializer("", arr(i64, {}, {1}));
  CHECK(g.value(g.add_node("Gather", {d3, scalar_ix}, {Attribute::Int("axis", 1)})).shape == (Shape{2, 5}));  // a scalar index drops the axis
  CHECK_ERR(g.add_node("Gather", {d3, a}), "indices must be int32 or int64");
  CHECK_ERR(g.add_node("Gather", {d3, i}, {Attribute::Int("axis", 3)}), "out of range");
  int gb = g.add_input("gb", DType::Bool, {2});
  CHECK_ERR(g.add_node("Gather", {gb, i}), "bool data");
  int c_ix = g.add_initializer("", arr(i64, {2}, {0, 4}));
  CHECK_ERR(g.add_node("Gather", {d3, c_ix}, {Attribute::Int("axis", 1)}), "out of range");
  CHECK(g.value(g.add_node("Gather", {d3, g.add_initializer("", arr(i64, {2}, {-1, 3}))}, {Attribute::Int("axis", 1)})).shape == (Shape{2, 2, 5}));
  // Erf: float only, same shape
  CHECK(g.value(g.add_node("Erf", {a})).shape == (Shape{2, 3}));
  CHECK_ERR(g.add_node("Erf", {i}), "float input needed");
}

static void shapes_conv_pool_norm() {
  hir::Graph g;
  int x = g.add_input("x", f32, {1, 2, 5, 5}), w = g.add_input("w", f32, {3, 2, 3, 3}), b = g.add_input("b", f32, {3});
  int ii = g.add_input("ii", i32, {1, 2, 5, 5});
  // Conv: floor((in + pads - dilation*(k-1) - 1)/stride) + 1
  CHECK(g.value(g.add_node("Conv", {x, w})).shape == (Shape{1, 3, 3, 3}));
  CHECK(g.value(g.add_node("Conv", {x, w, b}, {Attribute::Ints("strides", {2, 2}), Attribute::Ints("pads", {1, 1, 1, 1})})).shape == (Shape{1, 3, 3, 3}));
  CHECK(g.value(g.add_node("Conv", {x, w}, {Attribute::Ints("dilations", {2, 2})})).shape == (Shape{1, 3, 1, 1}));
  int w2 = g.add_input("w2", f32, {4, 1, 3, 3});                  // group 2: W has C/group = 1 input channel
  CHECK(g.value(g.add_node("Conv", {x, w2}, {Attribute::Int("group", 2), Attribute::Ints("kernel_shape", {3, 3})})).shape == (Shape{1, 4, 3, 3}));
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::String("auto_pad", "SAME_UPPER")}), "auto_pad SAME_UPPER is not supported");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::String("auto_pad", "VALID")}), "not supported");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::Ints("kernel_shape", {3, 2})}), "kernel_shape does not match");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::Ints("pads", {1, 1})}), "pads has 2 entries, expected 4");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::Ints("strides", {0, 1})}), "out of range");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::Int("group", 3)}), "must divide");
  CHECK_ERR(g.add_node("Conv", {x, w2}), "per group");
  CHECK_ERR(g.add_node("Conv", {x, w, w}), "B must have shape");
  CHECK_ERR(g.add_node("Conv", {ii, w}), "float inputs");
  CHECK_ERR(g.add_node("Conv", {x, w}, {Attribute::Ints("dilations", {5, 5}), Attribute::Ints("pads", {0, 0, 0, 0})}), "does not fit");
  int x1 = g.add_input("x1", f32, {1, 2, 7});
  int w1 = g.add_input("w1", f32, {2, 2, 3});
  CHECK(g.value(g.add_node("Conv", {x1, w1}, {Attribute::Ints("strides", {2}), Attribute::Ints("pads", {1, 1})})).shape == (Shape{1, 2, 4}));
  // MaxPool / AveragePool
  CHECK(g.value(g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("strides", {2, 2})})).shape == (Shape{1, 2, 2, 2}));
  CHECK(g.value(g.add_node("AveragePool", {x}, {Attribute::Ints("kernel_shape", {3, 3}), Attribute::Ints("pads", {1, 1, 1, 1})})).shape == (Shape{1, 2, 5, 5}));
  int x4 = g.add_input("x4", f32, {1, 1, 4, 4});
  CHECK(g.value(g.add_node("MaxPool", {x4}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("strides", {2, 2}), Attribute::Int("ceil_mode", 1)})).shape == (Shape{1, 1, 2, 2}));
  CHECK_ERR(g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("strides", {2, 2}), Attribute::Int("ceil_mode", 1)}), "ceil_mode=1 changes the output size");
  CHECK_ERR(g.add_node("MaxPool", {x}), "kernel_shape is required");
  CHECK_ERR(g.add_node("AveragePool", {x}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("dilations", {1, 1})}), "no dilations");
  CHECK_ERR(g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("pads", {2, 0, 0, 0})}), "reach a whole window");
  CHECK_ERR(g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {2})}), "kernel_shape has 1 entries");
  CHECK_ERR(g.add_node("MaxPool", {ii}, {Attribute::Ints("kernel_shape", {2, 2})}), "float input needed");
  // BatchNormalization (inference), InstanceNormalization, LayerNormalization
  int s = g.add_input("s", f32, {3}), bb = g.add_input("bb", f32, {3}), m = g.add_input("m", f32, {3}), v = g.add_input("v", f32, {3});
  CHECK_ERR(g.add_node("BatchNormalization", {x, s, bb, m, v}), "[C] = [2]");   // C is 2, the parameters are 3
  int s2 = g.add_input("s2", f32, {2}), b2 = g.add_input("b2", f32, {2}), m2 = g.add_input("m2", f32, {2}), v2 = g.add_input("v2", f32, {2});
  CHECK(g.value(g.add_node("BatchNormalization", {x, s2, b2, m2, v2}, {Attribute::Float("epsilon", 1e-3)})).shape == (Shape{1, 2, 5, 5}));
  CHECK_ERR(g.add_node("BatchNormalization", {x, s2, b2, m2, v2}, {Attribute::Int("training_mode", 1)}), "training_mode=1");
  CHECK(g.value(g.add_node("InstanceNormalization", {x, s2, b2})).shape == (Shape{1, 2, 5, 5}));
  CHECK_ERR(g.add_node("InstanceNormalization", {x1, s, bb}), "scale and B must have shape [C]");
  CHECK_ERR(g.add_node("InstanceNormalization", {g.add_input("r2", f32, {2, 3}), s2, b2}), "at least one spatial axis");
  int ls = g.add_input("ls", f32, {4, 5});
  CHECK(g.value(g.add_node("LayerNormalization", {x, g.add_input("ln_s2", f32, {5, 5}), g.add_input("ln_b2", f32, {5, 5})}, {Attribute::Int("axis", -2)})).shape == (Shape{1, 2, 5, 5}));
  int ln_s = g.add_input("ln_s", f32, {2, 5, 5}), ln_b = g.add_input("ln_b", f32, {2, 5, 5});
  CHECK(g.value(g.add_node("LayerNormalization", {x, ln_s, ln_b}, {Attribute::Int("axis", 1)})).shape == (Shape{1, 2, 5, 5}));
  CHECK_ERR(g.add_node("LayerNormalization", {x, ls}), "Scale must have the normalized shape");   // axis -1: [5]
  CHECK_ERR(g.add_node("LayerNormalization", {x, ln_s, ls}, {Attribute::Int("axis", 1)}), "B must have the normalized shape");
}

// ---- (b) numerical checks: references computed here, from the same (dtype-rounded) inputs ----

static V values_of(DType dt, const Shape& s, const V& raw) { return vals(arr(dt, s, raw)); }

static void gemm_check() {
  const int64_t M = 3, K = 4, N = 5;
  for (DType dt : {f32, f64})
    for (int tA = 0; tA < 2; tA++)
      for (int tB = 0; tB < 2; tB++) {
        const Shape as = tA ? Shape{K, M} : Shape{M, K}, bs = tB ? Shape{N, K} : Shape{K, N};
        const V av = values_of(dt, as, rand_vec(M * K, 1 + tA)), bv = values_of(dt, bs, rand_vec(K * N, 3 + tB)), cv = values_of(dt, {N}, rand_vec(N, 5));
        const double alpha = 0.5, beta = -2;   // exact in float32
        hir::Graph g;
        int a = g.add_input("a", dt, as), b = g.add_input("b", dt, bs), c = g.add_input("c", dt, {N});
        int y = g.add_node("Gemm", {a, b, c}, {Attribute::Float("alpha", alpha), Attribute::Float("beta", beta), Attribute::Int("transA", tA), Attribute::Int("transB", tB)}, "y");
        V want(static_cast<size_t>(M * N));
        for (int64_t m = 0; m < M; m++)
          for (int64_t n = 0; n < N; n++) {
            double s = 0;
            for (int64_t k = 0; k < K; k++) s += (tA ? av[static_cast<size_t>(k * M + m)] : av[static_cast<size_t>(m * K + k)]) * (tB ? bv[static_cast<size_t>(n * K + k)] : bv[static_cast<size_t>(k * N + n)]);
            want[static_cast<size_t>(m * N + n)] = alpha * s + beta * cv[static_cast<size_t>(n)];
          }
        std::map<std::string, Array> feeds{{"a", arr(dt, as, av)}, {"b", arr(dt, bs, bv)}, {"c", arr(dt, {N}, cv)}};
        Array got = run(g, y, feeds);
        CHECK(got.shape == (Shape{M, N}) && got.dtype == dt && near(vals(got), want, dt == f64 ? 1e-12 : 1e-6));
        round_trip(g, {y}, feeds, {got});
      }
}

static void gather_check() {
  // data (2,3,4) with a -0.0 (the selection must keep its sign), axis 1, negative and positive indices
  V dv = rand_vec(24, 9);
  dv[7] = -0.0;
  const Shape ds{2, 3, 4}, is{2, 2};
  const V idx{-1, 0, 2, 1};
  hir::Graph g;
  int d = g.add_input("d", f32, ds), ix = g.add_input("ix", i64, is);
  int y = g.add_node("Gather", {d, ix}, {Attribute::Int("axis", 1)}, "y");
  Array data = arr(f32, ds, dv), ia = arr(i64, is, idx);
  V dvals = vals(data);
  V want;
  for (int64_t a = 0; a < 2; a++)
    for (int64_t i = 0; i < 2; i++)
      for (int64_t j = 0; j < 2; j++)
        for (int64_t c = 0; c < 4; c++) {
          int64_t r = static_cast<int64_t>(idx[static_cast<size_t>(i * 2 + j)]);
          if (r < 0) r += 3;
          want.push_back(dvals[static_cast<size_t>((a * 3 + r) * 4 + c)]);
        }
  std::map<std::string, Array> feeds{{"d", data}, {"ix", ia}};
  Array got = run(g, y, feeds);
  CHECK(got.shape == (Shape{2, 2, 2, 4}));
  CHECK(vals(got) == want);   // exact (the signs of zeros are checked below)
  bool signs = got.data.size() == want.size();
  for (size_t k = 0; signs && k < want.size(); k++) signs = std::signbit(got.data[k].f) == std::signbit(want[k]);
  CHECK(signs);
  round_trip(g, {y}, feeds, {got});
  // int32 data with constant indices (an initializer), axis 0
  hir::Graph h;
  int hd = h.add_input("hd", i32, {3, 2});
  int hi = h.add_initializer("hi", arr(i32, {2}, {2, 0}));
  int hy = h.add_node("Gather", {hd, hi}, {}, "hy");
  std::map<std::string, Array> hfeeds{{"hd", arr(i32, {3, 2}, {1, 2, 3, 4, 5, 6})}};
  Array hgot = run(h, hy, hfeeds);
  CHECK(hgot.dtype == i32 && hgot.shape == (Shape{2, 2}) && vals(hgot) == (V{5, 6, 1, 2}));
  round_trip(h, {hy}, hfeeds, {hgot});
}

// The float32 correctly rounded erf (float of std::erf) is the reference for float32; the lowering is one rounding of a float64 series.
static void erf_check() {
  V xs;
  for (int k = 0; k <= 60000; k++) xs.push_back(-6.0 + k * (12.0 / 60000));
  for (double v : {0.0, -0.0, 1e-30, -1e-30, 3.9, 3.99, 4.0, -4.0, 4.5, 1e30, -1e30, 1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0}) xs.push_back(v);
  hir::Graph g;
  int x = g.add_input("x", f32, {static_cast<int64_t>(xs.size())});
  int y = g.add_node("Erf", {x}, {}, "y");
  std::map<std::string, Array> feeds{{"x", arr(f32, {static_cast<int64_t>(xs.size())}, xs)}};
  Array got = run(g, y, feeds);
  double max_ulp = 0;
  double at_ulp = 0;
  bool specials_ok = true;
  for (size_t k = 0; k < xs.size(); k++) {
    const float xf = static_cast<float>(xs[k]);
    const float ref = static_cast<float>(std::erf(static_cast<double>(xf)));
    const float gv = static_cast<float>(got.data[k].f);
    if (std::isnan(xf)) { specials_ok = specials_ok && std::isnan(gv); continue; }
    if (ref == 0 || std::isinf(ref)) { specials_ok = specials_ok && gv == ref && std::signbit(gv) == std::signbit(ref); continue; }
    const double ulp = std::nextafter(std::fabs(static_cast<double>(ref)), INFINITY) - std::fabs(static_cast<double>(ref));
    const double e = std::fabs(static_cast<double>(gv) - static_cast<double>(ref)) / ulp;
    if (e > max_ulp) { max_ulp = e; at_ulp = xf; }
  }
  CHECK(specials_ok);
  CHECK(max_ulp <= 1.0);   // one rounding of an error below 2e-15 relative: at most 1 ulp, and 0.5 ulp unless a value sits next to a rounding midpoint
  if (max_ulp == 0) std::printf("Erf float32: every one of %zu inputs equals the correctly rounded std::erf\n", xs.size());
  else std::printf("Erf float32: max error %.3f ulp (at x = %g) against the correctly rounded std::erf, over %zu inputs\n", max_ulp, at_ulp, xs.size());
  // float64: the series itself, against std::erf
  hir::Graph h;
  int hx = h.add_input("hx", f64, {static_cast<int64_t>(xs.size())});
  int hy = h.add_node("Erf", {hx}, {}, "hy");
  std::map<std::string, Array> hfeeds{{"hx", arr(f64, {static_cast<int64_t>(xs.size())}, xs)}};
  Array hgot = run(h, hy, hfeeds);
  double max_rel = 0, max_abs_small = 0;
  for (size_t k = 0; k < xs.size(); k++) {
    if (std::isnan(xs[k]) || std::isinf(xs[k])) continue;
    const double ref = std::erf(xs[k]), gv = hgot.data[k].f;
    if (std::fabs(ref) < 1e-3) max_abs_small = std::max(max_abs_small, std::fabs(gv - ref));
    else max_rel = std::max(max_rel, std::fabs(gv - ref) / std::fabs(ref));
  }
  CHECK(max_rel <= 1e-14 && max_abs_small <= 1e-17);   // measured: 4.3e-15 relative, 1e-19 absolute near 0
  std::printf("Erf float64: max relative error %.3g (|erf| >= 1e-3), max absolute error %.3g below it, against std::erf\n", max_rel, max_abs_small);
  round_trip(g, {y}, feeds, {got});
}

static void conv_check() {
  struct Case { Shape xs, ws, strides, dil, pb, pe; int64_t group; bool bias, constant; DType dt; };
  const std::vector<Case> cases = {
      {{2, 4, 5, 6}, {6, 2, 3, 2}, {2, 1}, {1, 2}, {1, 0}, {2, 1}, 2, true, false, f32},   // 2-D, groups, strides, dilations, asymmetric pads
      {{2, 4, 5, 6}, {6, 2, 3, 2}, {2, 1}, {1, 2}, {1, 0}, {2, 1}, 2, true, true, f64},    // the same with constant weights, float64
      {{1, 2, 7}, {2, 2, 3}, {2}, {1}, {1}, {1}, 1, false, false, f32},                      // 1-D without a bias
      {{1, 3, 4, 3, 2}, {4, 3, 2, 2, 1}, {1, 2, 1}, {1, 1, 1}, {0, 1, 0}, {1, 0, 1}, 1, true, false, f32},   // 3-D
  };
  for (const Case& c : cases) {
    const size_t d = c.xs.size() - 2;
    const int64_t N = c.xs[0], C = c.xs[1], M = c.ws[0];
    V xv = values_of(c.dt, c.xs, rand_vec(prod(c.xs), 21)), wv = values_of(c.dt, c.ws, rand_vec(prod(c.ws), 22)), bv = values_of(c.dt, {M}, rand_vec(M, 23));
    hir::Graph g;
    int x = g.add_input("x", c.dt, c.xs);
    int w = c.constant ? g.add_initializer("w", arr(c.dt, c.ws, wv)) : g.add_input("w", c.dt, c.ws);
    std::vector<int> ins{x, w};
    if (c.bias) ins.push_back(g.add_initializer("b", arr(c.dt, {M}, bv)));
    std::vector<Attribute> at{Attribute::Ints("strides", c.strides), Attribute::Ints("dilations", c.dil), Attribute::Int("group", c.group)};
    Shape pads = c.pb;
    pads.insert(pads.end(), c.pe.begin(), c.pe.end());
    at.push_back(Attribute::Ints("pads", pads));
    int y = g.add_node("Conv", ins, at, "y");
    const Shape os = g.value(y).shape;
    // reference: direct loops over the output positions, the kernel and the input channels of the group
    V want(static_cast<size_t>(prod(os)), 0.0);
    const Shape O(os.begin() + 2, os.end()), kernel(c.ws.begin() + 2, c.ws.end());
    const int64_t Cg = C / c.group;
    for (int64_t n = 0; n < N; n++)
      for (int64_t m = 0; m < M; m++) {
        const int64_t grp = m / (M / c.group);
        each_index(O, [&](const Shape& o) {
          double acc = c.bias ? bv[static_cast<size_t>(m)] : 0;
          for (int64_t ch = 0; ch < Cg; ch++)
            each_index(kernel, [&](const Shape& kap) {
              Shape at_x{n, grp * Cg + ch}, at_w{m, ch};
              for (size_t k = 0; k < d; k++) {
                const int64_t p = o[k] * c.strides[k] + kap[k] * c.dil[k] - c.pb[k];
                if (p < 0 || p >= c.xs[2 + k]) return;
                at_x.push_back(p);
              }
              at_w.insert(at_w.end(), kap.begin(), kap.end());
              acc += xv[static_cast<size_t>(flat(c.xs, at_x))] * wv[static_cast<size_t>(flat(c.ws, at_w))];
            });
          Shape oa{n, m};
          oa.insert(oa.end(), o.begin(), o.end());
          want[static_cast<size_t>(flat(os, oa))] = acc;
        });
      }
    std::map<std::string, Array> feeds{{"x", arr(c.dt, c.xs, xv)}};
    if (!c.constant) feeds["w"] = arr(c.dt, c.ws, wv);
    Array got = run(g, y, feeds);
    CHECK(got.shape == os && near(vals(got), want, c.dt == f64 ? 1e-12 : 1e-5));
    round_trip(g, {y}, feeds, {got});
  }
}

static void pool_check() {
  const Shape xs{2, 3, 6, 5};
  V xv = values_of(f32, xs, rand_vec(prod(xs), 31));
  struct Case { bool is_max; Shape kernel, strides, dil, pb, pe; bool include_pad; };
  const std::vector<Case> cases = {
      {true, {3, 2}, {2, 1}, {1, 1}, {1, 0}, {1, 1}, false},   // MaxPool, padded with -inf
      {true, {2, 2}, {1, 1}, {2, 1}, {0, 0}, {0, 0}, false},   // MaxPool with dilations
      {false, {3, 2}, {2, 1}, {1, 1}, {1, 0}, {1, 1}, false},  // AveragePool, the padding is not counted
      {false, {3, 2}, {2, 1}, {1, 1}, {1, 0}, {1, 1}, true},   // AveragePool, the padding is counted
  };
  for (const Case& c : cases) {
    hir::Graph g;
    int x = g.add_input("x", f32, xs);
    Shape pads = c.pb;
    pads.insert(pads.end(), c.pe.begin(), c.pe.end());
    std::vector<Attribute> at{Attribute::Ints("kernel_shape", c.kernel), Attribute::Ints("strides", c.strides), Attribute::Ints("pads", pads)};
    if (c.is_max) at.push_back(Attribute::Ints("dilations", c.dil));
    else if (c.include_pad) at.push_back(Attribute::Int("count_include_pad", 1));
    int y = g.add_node(c.is_max ? "MaxPool" : "AveragePool", {x}, at, "y");
    const Shape os = g.value(y).shape;
    const Shape O(os.begin() + 2, os.end());
    V want(static_cast<size_t>(prod(os)));
    for (int64_t n = 0; n < xs[0]; n++)
      for (int64_t ch = 0; ch < xs[1]; ch++)
        each_index(O, [&](const Shape& o) {
          double best = -INFINITY, sum = 0;
          int64_t valid = 0, slots = 0;
          each_index(c.kernel, [&](const Shape& kap) {
            Shape at_x{n, ch};
            for (size_t k = 0; k < 2; k++) {
              const int64_t p = o[k] * c.strides[k] + kap[k] * c.dil[k] - c.pb[k];
              if (p < 0 || p >= xs[2 + k]) { slots++; return; }   // padding
              at_x.push_back(p);
            }
            slots++;
            const double v = xv[static_cast<size_t>(flat(xs, at_x))];
            best = std::max(best, v);
            sum += v;
            valid++;
          });
          Shape oa{n, ch};
          oa.insert(oa.end(), o.begin(), o.end());
          double val = c.is_max ? best : sum / static_cast<double>(c.include_pad ? slots : valid);
          want[static_cast<size_t>(flat(os, oa))] = val;
        });
    std::map<std::string, Array> feeds{{"x", arr(f32, xs, xv)}};
    Array got = run(g, y, feeds);
    CHECK(got.shape == os && near(vals(got), want, 1e-6));
    round_trip(g, {y}, feeds, {got});
  }
}

static void norm_check() {
  const Shape xs{2, 3, 4, 5};
  V xv = values_of(f32, xs, rand_vec(prod(xs), 41));
  V sc = values_of(f32, {3}, rand_vec(3, 42)), bi = values_of(f32, {3}, rand_vec(3, 43)), mu = values_of(f32, {3}, rand_vec(3, 44)), va = values_of(f32, {3}, rand_vec(3, 45));
  for (double& v : va) v = v * 0.5 + 1.0;   // variances are positive
  const double eps = 1e-3;                  // an attribute is stored as float32: the references use that value
  const double epsf = static_cast<float>(eps);
  // BatchNormalization (inference)
  {
    hir::Graph g;
    int x = g.add_input("x", f32, xs), s = g.add_input("s", f32, {3}), b = g.add_input("b", f32, {3}), m = g.add_input("m", f32, {3}), v = g.add_input("v", f32, {3});
    int y = g.add_node("BatchNormalization", {x, s, b, m, v}, {Attribute::Float("epsilon", eps), Attribute::Int("training_mode", 0)}, "y");
    V want(xv.size());
    each_index(xs, [&](const Shape& at) {
      const size_t c = static_cast<size_t>(at[1]);
      want[static_cast<size_t>(flat(xs, at))] = (xv[static_cast<size_t>(flat(xs, at))] - mu[c]) * sc[c] / std::sqrt(va[c] + epsf) + bi[c];
    });
    std::map<std::string, Array> feeds{{"x", arr(f32, xs, xv)}, {"s", arr(f32, {3}, sc)}, {"b", arr(f32, {3}, bi)}, {"m", arr(f32, {3}, mu)}, {"v", arr(f32, {3}, va)}};
    Array got = run(g, y, feeds);
    CHECK(got.shape == xs && near(vals(got), want, 1e-5));
    round_trip(g, {y}, feeds, {got});
  }
  // InstanceNormalization: per (n, c) over the spatial axes, population variance
  {
    hir::Graph g;
    int x = g.add_input("x", f32, xs), s = g.add_input("s", f32, {3}), b = g.add_input("b", f32, {3});
    int y = g.add_node("InstanceNormalization", {x, s, b}, {Attribute::Float("epsilon", eps)}, "y");
    V want(xv.size());
    for (int64_t n = 0; n < 2; n++)
      for (int64_t c = 0; c < 3; c++) {
        double m = 0, q = 0;
        for (int64_t k = 0; k < 20; k++) m += xv[static_cast<size_t>((n * 3 + c) * 20 + k)];
        m /= 20;
        for (int64_t k = 0; k < 20; k++) q += (xv[static_cast<size_t>((n * 3 + c) * 20 + k)] - m) * (xv[static_cast<size_t>((n * 3 + c) * 20 + k)] - m);
        q /= 20;
        for (int64_t k = 0; k < 20; k++) {
          size_t i = static_cast<size_t>((n * 3 + c) * 20 + k);
          want[i] = (xv[i] - m) * sc[static_cast<size_t>(c)] / std::sqrt(q + epsf) + bi[static_cast<size_t>(c)];
        }
      }
    std::map<std::string, Array> feeds{{"x", arr(f32, xs, xv)}, {"s", arr(f32, {3}, sc)}, {"b", arr(f32, {3}, bi)}};
    Array got = run(g, y, feeds);
    CHECK(got.shape == xs && near(vals(got), want, 1e-5));
    round_trip(g, {y}, feeds, {got});
  }
  // LayerNormalization: over axes 1.. (the Scale and B are (3, 4, 5)), and over the last axis only (Scale and B are (5))
  for (int64_t axis : {1, -1}) {
    const Shape nshape = axis == 1 ? Shape{3, 4, 5} : Shape{5};
    V ls = values_of(f32, nshape, rand_vec(prod(nshape), 51)), lb = values_of(f32, nshape, rand_vec(prod(nshape), 52));
    hir::Graph g;
    int x = g.add_input("x", f32, xs), s = g.add_input("s", f32, nshape), b = g.add_input("b", f32, nshape);
    int y = g.add_node("LayerNormalization", {x, s, b}, {Attribute::Int("axis", axis), Attribute::Float("epsilon", eps)}, "y");
    const int64_t group = prod(nshape);   // the normalized group size
    V want(xv.size());
    for (int64_t outer = 0; outer < prod(xs) / group; outer++) {
      double m = 0, q = 0;
      for (int64_t k = 0; k < group; k++) m += xv[static_cast<size_t>(outer * group + k)];
      m /= static_cast<double>(group);
      for (int64_t k = 0; k < group; k++) q += (xv[static_cast<size_t>(outer * group + k)] - m) * (xv[static_cast<size_t>(outer * group + k)] - m);
      q /= static_cast<double>(group);
      for (int64_t k = 0; k < group; k++) {
        const size_t i = static_cast<size_t>(outer * group + k);
        want[i] = (xv[i] - m) / std::sqrt(q + epsf) * ls[static_cast<size_t>(k)] + lb[static_cast<size_t>(k)];
      }
    }
    std::map<std::string, Array> feeds{{"x", arr(f32, xs, xv)}, {"s", arr(f32, nshape, ls)}, {"b", arr(f32, nshape, lb)}};
    Array got = run(g, y, feeds);
    CHECK(got.shape == xs && near(vals(got), want, 1e-5));
    round_trip(g, {y}, feeds, {got});
  }
}

// ---- (d) models for tests/uop/onnx_check.py: onnx.checker (full check) and onnxruntime against the interpreter's values ----

static std::string json_array(const Array& a) {
  std::string o = "{\"dtype\":\"" + std::string(name(a.dtype)) + "\",\"shape\":[";
  for (size_t k = 0; k < a.shape.size(); k++) o += (k ? "," : "") + std::to_string(a.shape[k]);
  o += "],\"data\":[";
  for (size_t k = 0; k < a.data.size(); k++) {
    char buf[64];
    if (is_float(a.dtype)) std::snprintf(buf, sizeof buf, "%.17g", a.data[k].f);
    else std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(a.data[k].i));
    std::string num = buf;
    if (num == "nan" || num == "-nan") num = "null";
    else if (num == "inf") num = "1e999";
    else if (num == "-inf") num = "-1e999";
    o += (k ? "," : "") + num;
  }
  return o + "]}";
}

// DIR/<name>.onnx (the graph's outputs `outs`, named as their values) and DIR/<name>.json (the inputs and what the interpreter computes)
static void emit(const std::string& dir, const std::string& model, const hir::Graph& g, const std::vector<int>& outs, const std::map<std::string, Array>& feeds) {
  std::ofstream f(dir + "/" + model + ".onnx", std::ios::binary);
  const std::string bytes = g.to_onnx(outs, model);
  f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  std::string j = "{\"inputs\":{";
  bool first = true;
  for (const auto& kv : feeds) { j += (first ? "" : ",") + ("\"" + kv.first + "\":" + json_array(kv.second)); first = false; }
  j += "},\"outputs\":{";
  first = true;
  for (int o : outs) { j += (first ? "" : ",") + ("\"" + g.value(o).name + "\":" + json_array(run(g, o, feeds))); first = false; }
  std::ofstream(dir + "/" + model + ".json") << j << "}}";
}

static void write_models(const std::string& dir) {
  {  // Gemm with transposes, alpha, beta and a broadcast C; Erf after it
    hir::Graph g;
    int a = g.add_input("a", f32, {4, 3}), b = g.add_input("b", f32, {5, 4}), c = g.add_input("c", f32, {5});
    int y = g.add_node("Gemm", {a, b, c}, {Attribute::Float("alpha", 1.5), Attribute::Float("beta", 0.25), Attribute::Int("transA", 1), Attribute::Int("transB", 1)}, "gemm");
    int z = g.add_node("Erf", {y}, {}, "erf");
    emit(dir, "fwd_gemm_erf", g, {y, z}, {{"a", arr(f32, {4, 3}, values_of(f32, {4, 3}, rand_vec(12, 61)))}, {"b", arr(f32, {5, 4}, values_of(f32, {5, 4}, rand_vec(20, 62)))}, {"c", arr(f32, {5}, values_of(f32, {5}, rand_vec(5, 63)))}});
  }
  {  // Gather along axis 1 with negative indices (runtime) and along the last axis (constant indices)
    hir::Graph g;
    int d = g.add_input("d", f32, {2, 3, 4}), ix = g.add_input("ix", i64, {2, 2});
    int y = g.add_node("Gather", {d, ix}, {Attribute::Int("axis", 1)}, "g1");
    int c = g.add_initializer("ci", arr(i32, {2}, {3, 0}));
    int z = g.add_node("Gather", {d, c}, {Attribute::Int("axis", -1)}, "g2");
    emit(dir, "fwd_gather", g, {y, z}, {{"d", arr(f32, {2, 3, 4}, values_of(f32, {2, 3, 4}, rand_vec(24, 71)))}, {"ix", arr(i64, {2, 2}, {-1, 0, 2, -3})}});
  }
  {  // Conv: groups, strides, dilations, pads, a bias; the weights are a runtime input in one model and a constant in the other
    for (int constant = 0; constant < 2; constant++) {
      hir::Graph g;
      int x = g.add_input("x", f32, {2, 4, 5, 6});
      int w = constant ? g.add_initializer("w", arr(f32, {6, 2, 3, 2}, values_of(f32, {6, 2, 3, 2}, rand_vec(72, 81)))) : g.add_input("w", f32, {6, 2, 3, 2});
      int b = g.add_initializer("b", arr(f32, {6}, values_of(f32, {6}, rand_vec(6, 82))));
      int y = g.add_node("Conv", {x, w, b}, {Attribute::Ints("strides", {2, 1}), Attribute::Ints("dilations", {1, 2}), Attribute::Ints("pads", {1, 0, 2, 1}), Attribute::Int("group", 2)}, "conv");
      std::map<std::string, Array> feeds{{"x", arr(f32, {2, 4, 5, 6}, values_of(f32, {2, 4, 5, 6}, rand_vec(240, 83)))}};
      if (!constant) feeds["w"] = arr(f32, {6, 2, 3, 2}, values_of(f32, {6, 2, 3, 2}, rand_vec(72, 81)));
      emit(dir, constant ? "fwd_conv_const" : "fwd_conv", g, {y}, feeds);
    }
  }
  {  // MaxPool (dilations, -inf padding, ceil_mode with the same size), AveragePool with and without counting the padding
    hir::Graph g;
    int x = g.add_input("x", f32, {2, 3, 6, 5});
    int m = g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {3, 2}), Attribute::Ints("strides", {2, 1}), Attribute::Ints("dilations", {1, 1}), Attribute::Ints("pads", {1, 0, 1, 1})}, "maxp");
    int m2 = g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {2, 2}), Attribute::Ints("dilations", {2, 1}), Attribute::Int("ceil_mode", 0)}, "maxd");
    int a1 = g.add_node("AveragePool", {x}, {Attribute::Ints("kernel_shape", {3, 2}), Attribute::Ints("strides", {2, 1}), Attribute::Ints("pads", {1, 0, 1, 1})}, "avg");
    int a2 = g.add_node("AveragePool", {x}, {Attribute::Ints("kernel_shape", {3, 2}), Attribute::Ints("strides", {2, 1}), Attribute::Ints("pads", {1, 0, 1, 1}), Attribute::Int("count_include_pad", 1)}, "avgi");
    emit(dir, "fwd_pool", g, {m, m2, a1, a2}, {{"x", arr(f32, {2, 3, 6, 5}, values_of(f32, {2, 3, 6, 5}, rand_vec(180, 91)))}});
  }
  {  // BatchNormalization (inference), InstanceNormalization, LayerNormalization over the trailing axes
    hir::Graph g;
    int x = g.add_input("x", f32, {2, 3, 4, 5}), s = g.add_input("s", f32, {3}), b = g.add_input("b", f32, {3}), mu = g.add_input("mu", f32, {3}), va = g.add_input("va", f32, {3});
    int bn = g.add_node("BatchNormalization", {x, s, b, mu, va}, {Attribute::Float("epsilon", 1e-3)}, "bn");
    int in = g.add_node("InstanceNormalization", {x, s, b}, {}, "inorm");
    int ls = g.add_input("ls", f32, {4, 5}), lb = g.add_input("lb", f32, {4, 5});
    int ln = g.add_node("LayerNormalization", {x, ls, lb}, {Attribute::Int("axis", -2)}, "lnorm");
    V vv = values_of(f32, {3}, rand_vec(3, 96));
    for (double& v : vv) v = v * 0.5 + 1.0;
    emit(dir, "fwd_norms", g, {bn, in, ln}, {{"x", arr(f32, {2, 3, 4, 5}, values_of(f32, {2, 3, 4, 5}, rand_vec(120, 92)))}, {"s", arr(f32, {3}, values_of(f32, {3}, rand_vec(3, 93)))},
                                              {"b", arr(f32, {3}, values_of(f32, {3}, rand_vec(3, 94)))}, {"mu", arr(f32, {3}, values_of(f32, {3}, rand_vec(3, 95)))},
                                              {"va", arr(f32, {3}, vv)}, {"ls", arr(f32, {4, 5}, values_of(f32, {4, 5}, rand_vec(20, 97)))}, {"lb", arr(f32, {4, 5}, values_of(f32, {4, 5}, rand_vec(20, 98)))}});
  }
}

// The C backend (nfcuop_cgen.hpp, compiled with cc) gives the interpreter's bits for the operators' lowerings, including the -0.0
// selection of Gather, the -inf padding of MaxPool and the float64 Erf series.
static void c_backend() {
  hir::Graph g;
  int x = g.add_input("x", f32, {2, 3, 5, 4});
  int ix = g.add_input("ix", i64, {2});
  int gath = g.add_node("Gather", {x, ix}, {Attribute::Int("axis", 2)});
  int mp = g.add_node("MaxPool", {x}, {Attribute::Ints("kernel_shape", {3, 2}), Attribute::Ints("strides", {2, 1}), Attribute::Ints("pads", {1, 0, 1, 1})});
  int ap = g.add_node("AveragePool", {x}, {Attribute::Ints("kernel_shape", {3, 2}), Attribute::Ints("pads", {1, 0, 1, 1})});
  int ef = g.add_node("Erf", {x});
  int w = g.add_input("w", f32, {2, 3, 2, 2});
  int cv = g.add_node("Conv", {x, w}, {Attribute::Ints("pads", {1, 1, 0, 0}), Attribute::Ints("dilations", {1, 2})});
  V xv = values_of(f32, {2, 3, 5, 4}, rand_vec(120, 101));
  xv[3] = -0.0;
  xv[40] = -5.5;
  xv[60] = 0.0 / 0.0;
  std::map<std::string, Array> feeds{{"x", arr(f32, {2, 3, 5, 4}, xv)}, {"ix", arr(i64, {2}, {-1, 2})}, {"w", arr(f32, {2, 3, 2, 2}, rand_vec(24, 102))}};
  for (int y : {gath, mp, ap, ef, cv}) {
    Array want = run(g, y, feeds);
    ut::Session u;
    u.backend = ut::Session::Backend::C;
    hir::Lowerer low(g, u);
    Array got = u.eval(low.get(y), feeds);
    CHECK(same(got, want));
  }
}

int main(int argc, char** argv) {
  shapes();
  shapes_conv_pool_norm();
  gemm_check();
  gather_check();
  erf_check();
  conv_check();
  pool_check();
  norm_check();
  c_backend();
  if (argc > 1) write_models(argv[1]);
  if (failed) { std::printf("%d of %d checks FAILED\n", failed, checks); return 1; }
  std::printf("%d checks passed\n", checks);
  return 0;
}
