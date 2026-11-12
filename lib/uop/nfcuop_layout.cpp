// nfcuop layout: see nfcuop_layout.hpp and docs/notes/uop-layout.md.
#include "nfcuop_layout.hpp"

#include <limits>

namespace nfcuop::layout {

const char* axis_name(Axis a) { return a == Axis::Row ? "row" : "col"; }

Solution solve(const Problem& p) {
  const Avx2F32& target = p.target;
  Solution best;
  std::map<std::string, const Tensor*> by_name;
  for (const Tensor& t : p.tensors) by_name[t.name] = &t;

  // Mixed-radix counter over the variant choices.
  for (const Op& op : p.ops)
    if (op.variants.empty()) return best;  // infeasible: an op with no way to compute it
  std::vector<size_t> pick(p.ops.size(), 0);
  double best_cost = std::numeric_limits<double>::infinity();
  while (true) {
    // Evaluate this combination.
    std::map<std::string, Axis> layout;
    for (const Tensor& t : p.tensors)
      if (t.given) layout[t.name] = *t.given;
    double cost = 0, repair_cost = 0;
    std::vector<Repair> repairs;
    std::vector<std::string> chosen;
    for (size_t i = 0; i < p.ops.size(); ++i) {
      const Op& op = p.ops[i];
      const Variant& v = op.variants[pick[i]];
      chosen.push_back(v.name);
      cost += v.instructions;
      for (const std::string& in : op.inputs) {
        auto need = v.requires_lane.find(in);
        auto have = layout.find(in);
        if (need == v.requires_lane.end() || have == layout.end() || have->second == need->second) continue;
        const Tensor* t = by_name.at(in);
        Repair r{op.name, in, have->second, need->second, t->numel() * target.transpose_instr_per_elem};
        repair_cost += r.instructions;
        repairs.push_back(r);
      }
      for (const auto& [name, axis] : v.produces_lane) layout[name] = axis;
      if (!v.produces_lane.count(op.output)) layout.erase(op.output);
    }
    cost += repair_cost;
    if (cost < best_cost) {
      best_cost = cost;
      best.feasible = true;
      best.cost = cost;
      best.repair_cost = repair_cost;
      best.variant = chosen;
      best.layout = layout;
      best.repairs = repairs;
    }
    // Advance the counter.
    size_t i = 0;
    for (; i < pick.size(); ++i) {
      if (++pick[i] < p.ops[i].variants.size()) break;
      pick[i] = 0;
    }
    if (i == pick.size()) break;
  }
  return best;
}

Problem gemm_rowsum(int64_t M, int64_t N, int64_t K, const Avx2F32& target) {
  Problem p;
  p.target = target;
  p.tensors = {
      {"A", M, K, Axis::Col},  // row-major
      {"B", K, N, Axis::Col},  // row-major
      {"C", M, N, std::nullopt},
      {"R", M, 1, std::nullopt},
  };
  const double fma = double(M) * double(N) * double(K) / target.lanes;  // one ymm FMA does 8 multiply-adds
  const double store_adds = double(M) * double(N) / target.lanes;       // the N/8 vector adds per row, or per 8 rows
  Op gemm{"gemm", {"A", "B"}, "C", {}};
  gemm.variants.push_back({"avx2-vec-n", {{"B", Axis::Col}}, {{"C", Axis::Col}}, fma});
  gemm.variants.push_back({"avx2-vec-m", {{"A", Axis::Row}}, {{"C", Axis::Row}}, fma});
  Op rowsum{"rowsum", {"C"}, "R", {}};
  rowsum.variants.push_back({"reduce-vertical", {{"C", Axis::Row}}, {}, store_adds});
  rowsum.variants.push_back({"reduce-horizontal", {{"C", Axis::Col}}, {},
                             store_adds + double(M) * target.hsum_instr_per_row});
  p.ops = {gemm, rowsum};
  return p;
}

}  // namespace nfcuop::layout
