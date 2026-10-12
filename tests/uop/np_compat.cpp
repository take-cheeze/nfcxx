// Evaluates a fixed list of numpy-style expressions with nfcuop::np and writes the results as JSON to argv[1], for
// tests/uop/np_compat.py, which evaluates the same expressions with real numpy and compares (docs/notes/uop.md,
// "numpy compatibility"). The expressions and inputs here and in the script must stay in step, name for name.
#include <cmath>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "nfcuop_np.hpp"

using namespace nfcuop;
using namespace nfcuop::np;

int main(int argc, char** argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: np_compat OUT.json\n"); return 2; }
  Session np;
  const DType i32 = DType::Int32;
  Tensor a = np.array({1, 2, 3, 4, 5, 6}, {2, 3});
  Tensor b = np.array({10, 20, 30});
  Tensor ia = np.array({7, -7, 3, -3, 2, -5}, {2, 3}, i32);
  Tensor ib = np.array({2, -2, 3}, i32);
  Tensor m = np.arange(24).reshape({2, 3, 4});
  Tensor v = np.array({-2, -0.5, 0, 0.5, 2});
  Tensor bo = np.array({1, 0, 1, 0, 0, 1}, {2, 3}, DType::Bool);
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
  CASE("where", where(a > 3, a, np.scalar(0))); CASE("maximum_s", maximum(a, np.scalar(3)));
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
#undef CASE
  std::ofstream f(argv[1]);
  f << "{";
  for (size_t k = 0; k < c.size(); k++) {
    Array r = c[k].second.numpy();
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
  std::printf("%zu expressions evaluated\n", c.size());
  return 0;
}
