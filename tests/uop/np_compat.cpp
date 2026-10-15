// Evaluates a fixed list of numpy-style expressions with nfcuop::np and writes the results as JSON to argv[1], for
// tests/uop/np_compat.py, which evaluates the same expressions with real numpy and compares (docs/notes/uop.md,
// "numpy compatibility"). The expressions and inputs here and in the script must stay in step, name for name.
// argv[2] == "64" sets the session's default dtypes to float64 and int64 (numpy's). Every expression is also run through the
// C backend, and the program fails if it differs from the interpreter in a single bit.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: np_compat OUT.json [64]\n"); return 2; }
  Session np;
  if (argc > 2 && std::string(argv[2]) == "64") { np.default_float = DType::Float64; np.default_int = DType::Int64; }
  const DType i32 = DType::Int32;
  const DType f32 = DType::Float32;   // the inputs are float32 whatever the defaults are, like the numpy side
  Tensor a = np.array({1, 2, 3, 4, 5, 6}, {2, 3}, f32);
  Tensor b = np.array({10, 20, 30}, f32);
  Tensor ia = np.array({7, -7, 3, -3, 2, -5}, {2, 3}, i32);
  Tensor ib = np.array({2, -2, 3}, i32);
  Tensor m = np.arange(24, DType::Float32).reshape({2, 3, 4});
  Tensor v = np.array({-2, -0.5, 0, 0.5, 2}, f32);
  Tensor bo = np.array({1, 0, 1, 0, 0, 1}, {2, 3}, DType::Bool);
  Tensor sv = np.array({3, -1, 2, 2, 0.5, -7}, {2, 3}, f32);   // with a tie (the two 2s)
  Tensor ii = np.array({2, 0, 1, 1, 2, 0}, {2, 3}, i32);       // indices along axis 1
  Tensor ss = np.array({-2, 0, 1, 1, 4}, f32);                 // sorted, with a repeat
  Tensor sq = np.array({1, 1.5, -3, 4}, f32);
  Tensor w2 = np.array({5, 6}, f32);
  std::vector<std::pair<std::string, Tensor>> c;
#define CASE(name, expr) c.push_back({name, expr})
  CASE("add", a + b); CASE("sub", a - b); CASE("mul", a * b); CASE("div", a / b);
  CASE("add_s", a + 1); CASE("radd_s", 2 * a); CASE("sub_f", a - 0.5); CASE("rdiv_s", 3 / a); CASE("neg", -a);
  CASE("square", a * a); CASE("abs", (a - 3).abs());
  CASE("iadd", ia + ib); CASE("imul", ia * ib); CASE("isub", ia - ib); CASE("idiv_true", ia / ib);
  CASE("ifloordiv", floor_divide(ia, ib)); CASE("imod", ia % ib);
  CASE("ifloordiv_s", floor_divide(ia, np.scalar(2, i32))); CASE("imod_s", ia % 3);
  CASE("gt", a > 2); CASE("le", a <= b); CASE("eq", a == a); CASE("ne_s", a != 2);
  CASE("and", (a > 2) & (a < 5)); CASE("or", (a < 2) | (a > 5)); CASE("xor", (a > 2) ^ (a > 4));
  CASE("not", logical_not(a > 2)); CASE("band", bo & (a > 2));
  CASE("iand", ia & ib); CASE("ior", ia | ib); CASE("ixor", ia ^ ib);
  CASE("where", where(a > 3, a, np.scalar(0, f32))); CASE("maximum_s", maximum(a, np.scalar(3, f32)));
  CASE("minimum", minimum(a, b)); CASE("clip", a.clip(2, 5));
  CASE("sum_all", a.sum()); CASE("sum0", a.sum(0)); CASE("sum1k", a.sum(1, true));
  CASE("mean_all", a.mean()); CASE("mean0", a.mean(0)); CASE("max_all", a.max()); CASE("min1", a.min(1));
  CASE("isum", ia.sum()); CASE("imax0", ia.max(0)); CASE("imin", ia.min()); CASE("bsum", bo.sum());
  CASE("var", a.var()); CASE("std0", a.stddev(Axes{0})); CASE("sum02", m.sum(Axes{0, 2})); CASE("maxlast", m.max(-1));
  CASE("imean", ia.mean());
  CASE("T", a.T()); CASE("reshape", a.reshape({3, 2})); CASE("reshape_1", a.reshape({-1}));
  CASE("transpose3", m.transpose({2, 0, 1})); CASE("swapaxes", m.swapaxes(0, 2)); CASE("flatten", a.flatten());
  CASE("expand_dims", a.expand_dims(1)); CASE("squeeze", a.expand_dims(1).squeeze());
  CASE("broadcast_to", b.broadcast_to({2, 3}));
  CASE("astype_i", a.astype(i32)); CASE("astype_f", ia.astype(DType::Float32)); CASE("neg_cast", (-a).astype(i32));
  CASE("slice1", m.slice(1, 1, 3).slice(2, None, None, 2)); CASE("slice_rev", m.slice(2, None, None, -1));
  CASE("slice_int", m.at(1)); CASE("slice_last", m.at(-1, 1)); CASE("slice_rev0", a.slice(0, None, None, -1));
  CASE("slice_col", a.slice(1, 1, None)); CASE("slice_mixed", m.at(0).slice(0, 1, None).slice(1, 1, 3));
  CASE("slice_neg", m.slice(2, -3, -1));
  CASE("concat0", concatenate({a, a}, 0)); CASE("concat1", concatenate({a, a * 2}, 1));
  CASE("stack0", stack({a, a + 1})); CASE("stack2", stack({a, a + 1}, 2));
  CASE("exp", v.exp()); CASE("log", (v.abs() + 1).log()); CASE("sqrt", v.abs().sqrt()); CASE("sin", v.sin());
  CASE("cos", v.cos()); CASE("tanh", v.tanh()); CASE("sigmoid", v.sigmoid()); CASE("relu", v.relu());
  CASE("recip", v.reciprocal()); CASE("softmax", a.softmax()); CASE("logsoftmax", a.log_softmax());
  CASE("matmul_aat", matmul(a, a.T())); CASE("matmul_ab", matmul(a, b)); CASE("matmul_ba", matmul(b, a.T()));
  CASE("matmul_batch", matmul(m, np.ones({4, 2}))); CASE("matmul_gram", matmul(m, m.transpose({0, 2, 1})));
  CASE("matmul_vv", matmul(b, b)); CASE("matmul_int", matmul(ia, ia.T()));
  CASE("arange", np.arange(5)); CASE("arange_step", np.arange(1.0, 2.0, 0.25)); CASE("linspace", np.linspace(0, 1, 5));
  CASE("eye", np.eye(3)); CASE("zeros", np.zeros({2, 2})); CASE("ones_i", np.ones({2}, i32)); CASE("full", np.full({2}, 7));
  CASE("floor", v.floor()); CASE("ceil", v.ceil()); CASE("isnan", v.log().isnan()); CASE("isinf", v.reciprocal().isinf());
  CASE("ifloor", ia.floor()); CASE("pow_f", pow(v.abs() + 1, v)); CASE("pow_s", pow(a, 2)); CASE("ipow", pow(ia, 2));
  CASE("cumsum0", a.cumsum(0)); CASE("cumsum_all", m.cumsum(2)); CASE("icumsum", ia.cumsum(1));
  CASE("prod0", a.prod(0)); CASE("prod_all", a.prod()); CASE("iprod", ia.prod(0));
  CASE("argmax0", a.argmax(0)); CASE("argmin1", a.argmin(1)); CASE("argmax_all", ia.argmax());
  CASE("tile", tile(a, {2, 1})); CASE("tile1", tile(b, 2));
  CASE("take", take(a, np.array({2, 0}, i32), 1)); CASE("take_flat", take(ia, np.array({5, -1}, i32)));
  // the Array API functions (and the numpy ones next to them): sorting, searching, triangles, grids, rolls, einsum, ...
  CASE("sort1", sort(sv, 1)); CASE("sort0_desc", sort(sv, 0, true)); CASE("argsort1", argsort(sv, 1));
  CASE("argsort_desc", argsort(sv, 1, true)); CASE("take_along", take_along_axis(sv, ii, 1));
  CASE("searchsorted_l", searchsorted(ss, sq)); CASE("searchsorted_r", searchsorted(ss, sq, true));
  CASE("tril", tril(m, -1)); CASE("triu", triu(a, 1)); CASE("meshgrid_xy", meshgrid({b, w2})[0]);
  CASE("meshgrid_ij", meshgrid({b, w2}, false)[1]); CASE("roll_ax", roll(a, 1, 1)); CASE("roll_flat", roll(m, -3));
  CASE("repeat_ax", repeat(a, 2, 1)); CASE("repeat_flat", repeat(b, 2)); CASE("moveaxis", moveaxis(m, 0, -1));
  CASE("concat", concat({a, a + 1}, 0)); CASE("cumprod0", cumprod(a, 0)); CASE("cumprod_flat", cumprod(a));
  CASE("cumsum_init", cumulative_sum(a, 1, true)); CASE("cumprod_init", cumulative_prod(b, 0, true));
  CASE("einsum_mm", einsum("ij,jk->ik", {a, a.T()})); CASE("einsum_implicit", einsum("ij,jk", {a, a.T()}));
  CASE("einsum_tr", einsum("ij->ji", {a})); CASE("einsum_batch", einsum("bij,bjk->bik", {m, m.transpose({0, 2, 1})}));
  CASE("einsum_outer", einsum("i,j->ij", {b, b})); CASE("tensordot1", tensordot(a, a.T(), 1));
  CASE("vecdot", vecdot(a, a)); CASE("matrix_transpose", matrix_transpose(m));
  CASE("count_nz", count_nonzero(sv, Axes{1})); CASE("sign", sign(sv)); CASE("trunc", trunc(sv * 0.7));
  CASE("isfinite", isfinite(sv.log())); CASE("logical_xor", logical_xor(bo, a > 2)); CASE("bitwise_inv", bitwise_invert(ia));
  CASE("all_axis", all(bo, Axes{0})); CASE("any_all", any(a > 5)); CASE("copy", copy(a));
  CASE("zeros_like_i", zeros_like(a, i32)); CASE("full_like", full_like(a, 7)); CASE("ones_like_i", ones_like(ia));
  CASE("linspace_noend", np.linspace(0, 1, 4, {}, false)); CASE("eye_k", np.eye(2, 3, 1));
  CASE("std_corr", a.stddev(Axes{1}, false, 1)); CASE("var_corr", a.var(Axes{0}, true, 1));
#undef CASE
  std::vector<Tensor> all;
  for (const auto& e : c) all.push_back(e.second);
  std::vector<Array> results = np.eval_all(all);
  np.backend = ut::Session::Backend::C;
  std::vector<Array> viaC = np.eval_all(all);   // one compiled program for all the expressions
  int mismatches = 0;
  for (size_t k = 0; k < c.size(); k++) {
    bool ok = results[k].dtype == viaC[k].dtype && results[k].shape == viaC[k].shape && results[k].data.size() == viaC[k].data.size();
    for (size_t j = 0; ok && j < results[k].data.size(); j++) {
      const Scalar &x = results[k].data[j], &y = viaC[k].data[j];
      ok = (std::isnan(x.f) && std::isnan(y.f)) || x == y;
    }
    if (!ok) { std::printf("MISMATCH %s: the C backend differs from the interpreter\n", c[k].first.c_str()); mismatches++; }
  }
  std::ofstream f(argv[1]);
  f << "{";
  for (size_t k = 0; k < c.size(); k++) {
    const Array& r = results[k];
    f << (k ? "," : "") << "\"" << c[k].first << "\":{\"dtype\":\"" << name(r.dtype) << "\",\"shape\":[";
    for (size_t j = 0; j < r.shape.size(); j++) f << (j ? "," : "") << r.shape[j];
    f << "],\"data\":[";
    for (size_t j = 0; j < r.data.size(); j++) {
      char buf[64];
      if (is_float(r.dtype)) std::snprintf(buf, sizeof buf, "%.17g", r.data[j].f); else std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(r.data[j].i));
      std::string num = buf;
      if (num == "nan" || num == "-nan") num = "null"; else if (num == "inf") num = "1e999"; else if (num == "-inf") num = "-1e999";
      f << (j ? "," : "") << num;
    }
    f << "]}";
  }
  f << "}";
  std::printf("%zu expressions evaluated, %d differ between the interpreter and C\n", c.size(), mismatches);
  return mismatches ? 1 : 0;
}
