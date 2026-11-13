// nfcuop layout: see nfcuop_layout.hpp and docs/notes/uop-layout.md.
#include "nfcuop_layout.hpp"

#include <limits>

namespace nfcuop::layout {

const char* axis_name(Axis a) { return a == Axis::Row ? "row" : "col"; }

namespace {
// The instructions of a threadable variant at the best power-of-two thread count up to max_threads, and that count.
double threaded_cost(double work, const Avx2F32& t, int& threads) {
  double best = work;
  threads = 1;
  for (int n = 2; n <= t.max_threads; n *= 2) {
    const double c = work * (t.serial_fraction + (1 - t.serial_fraction) / n) + t.thread_spawn_instr * (n - 1);
    if (c < best) {
      best = c;
      threads = n;
    }
  }
  return best;
}

// Instructions per element of a tensor held in storage s.
double storage_instr_per_elem(const Avx2F32& t, Storage s) {
  switch (s) {
    case Storage::Strided: return t.strided_instr_per_elem;
    case Storage::Blocked8: return t.blocked_instr_per_elem;
    case Storage::Panel16: return t.panel_instr_per_elem;
  }
  return 0;
}
}  // namespace

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
    double cost = 0, repair_cost = 0, required_storage_cost = 0;
    int threads = 1;
    std::map<std::string, Storage> required_storage;  // inputs a chosen variant needs in a storage (not enumerated)
    std::vector<Repair> repairs;
    std::vector<std::string> chosen;
    std::vector<std::string> row_lane;          // the Row-lane tensors this choice holds (their storage is enumerated)
    auto add_row_lane = [&](const std::string& name) {
      for (const std::string& r : row_lane)
        if (r == name) return;
      row_lane.push_back(name);
    };
    for (size_t i = 0; i < p.ops.size(); ++i) {
      const Op& op = p.ops[i];
      const Variant& v = op.variants[pick[i]];
      chosen.push_back(v.name);
      int variant_threads = 1;
      cost += v.threadable ? threaded_cost(v.instructions, target, variant_threads) : v.instructions;
      if (variant_threads > threads) threads = variant_threads;
      for (const std::string& in : op.inputs) {
        auto need = v.requires_lane.find(in);
        auto have = layout.find(in);
        if (need == v.requires_lane.end() || have == layout.end() || have->second == need->second) continue;
        const Tensor* t = by_name.at(in);
        Repair r{op.name, in, have->second, need->second, t->numel() * target.transpose_instr_per_elem};
        repair_cost += r.instructions;
        repairs.push_back(r);
        if (need->second == Axis::Row) add_row_lane(in);  // the repaired copy is in Row lanes
      }
      for (const auto& [name, st] : v.requires_storage) {
        const Tensor* t = by_name.at(name);
        required_storage_cost += double(t->numel()) * storage_instr_per_elem(target, st);
        required_storage[name] = st;
      }
      for (const auto& [name, axis] : v.produces_lane) {
        layout[name] = axis;
        if (axis == Axis::Row) add_row_lane(name);
      }
      if (!v.produces_lane.count(op.output)) layout.erase(op.output);
    }
    cost += repair_cost;
    // Storage of the Row-lane tensors: bit i of mask set means row_lane[i] is Blocked8. Mask 0 (all Strided) is tried
    // first, so it wins ties, such as a zero strided penalty.
    uint32_t storage_mask = 0;
    double row_storage_cost = std::numeric_limits<double>::infinity();
    for (uint32_t mask = 0; mask < (1u << row_lane.size()); ++mask) {
      double sc = 0;
      for (size_t i = 0; i < row_lane.size(); ++i) {
        const Storage st = (mask >> i) & 1 ? Storage::Blocked8 : Storage::Strided;
        sc += double(by_name.at(row_lane[i])->numel()) * storage_instr_per_elem(target, st);
      }
      if (sc < row_storage_cost) {
        row_storage_cost = sc;
        storage_mask = mask;
      }
    }
    const double storage_cost = row_storage_cost + required_storage_cost;
    cost += storage_cost;
    if (cost < best_cost) {
      best_cost = cost;
      best.feasible = true;
      best.cost = cost;
      best.repair_cost = repair_cost;
      best.threads = threads;
      best.storage_cost = storage_cost;
      best.variant = chosen;
      best.layout = layout;
      best.repairs = repairs;
      best.storage.clear();
      for (size_t i = 0; i < row_lane.size(); ++i)
        best.storage[row_lane[i]] = (storage_mask >> i) & 1 ? Storage::Blocked8 : Storage::Strided;
      for (const auto& [name, st] : required_storage) best.storage[name] = st;
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
  gemm.variants.push_back({"avx2-vec-n", {{"B", Axis::Col}}, {{"C", Axis::Col}}, fma, {}, false});
  gemm.variants.push_back({"avx2-vec-m", {{"A", Axis::Row}}, {{"C", Axis::Row}}, fma, {}, false});
  if (M % 6 == 0 && N % 16 == 0) {  // the register-blocked kernel's shapes (6 rows by 16 columns)
    Variant packed{"avx2-packed-n", {{"B", Axis::Col}}, {{"C", Axis::Col}}, fma * target.register_blocked_fma_factor, {}, false};
    packed.requires_storage["B"] = Storage::Panel16;
    packed.threadable = true;
    gemm.variants.push_back(packed);
  }
  Op rowsum{"rowsum", {"C"}, "R", {}};
  rowsum.variants.push_back({"reduce-vertical", {{"C", Axis::Row}}, {}, store_adds, {}, false});
  rowsum.variants.push_back({"reduce-horizontal", {{"C", Axis::Col}}, {},
                             store_adds + double(M) * target.hsum_instr_per_row, {}, false});
  p.ops = {gemm, rowsum};
  return p;
}

}  // namespace nfcuop::layout
