// nfcuop layout: see nfcuop_layout.hpp and docs/notes/uop-layout.md.
#include "nfcuop_layout.hpp"

#include <limits>

namespace nfcuop::layout {

const char* axis_name(Axis a) { return a == Axis::Row ? "row" : "col"; }

namespace {
// The instructions of a threadable variant at the best power-of-two thread count up to max_threads, and that count.
double threaded_cost(double work, const F32Target& t, int& threads) {
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
double storage_instr_per_elem(const F32Target& t, Storage s) {
  switch (s) {
    case Storage::Strided: return t.strided_instr_per_elem;
    case Storage::Blocked8: return t.blocked_instr_per_elem;
    case Storage::Panel: return t.panel_instr_per_elem;
  }
  return 0;
}
}  // namespace

Solution solve(const Problem& p) {
  const F32Target& target = p.target;
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
    bool excluded = false;
    for (const auto& [a, b] : p.incompatible)
      for (const std::string& x : chosen)
        for (const std::string& y : chosen)
          if (x == a && y == b) excluded = true;
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
    if (!excluded && cost < best_cost) {
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

F32Target avx512_f32() {
  F32Target t;
  t.isa = "avx512";
  t.lanes = 16;
  t.tile_cols = 32;
  t.transpose_instr_per_elem = 0.25;   // a 16x16 transpose is 64 unpack and shuffle instructions on 256 elements (not used)
  t.hsum_instr_per_row = 8.0;          // reduce_add of one zmm (assumed; not measured)
  t.panel_instr_per_elem = 2.0 / 16.0; // one load and one store per zmm
  // Measured on this host at 504 x 512 x 512, one thread: the packed kernel 1901 us, a naive AVX-512 kernel (no packing,
  // no register blocking, B read per k) 7790 to 8229 us. Ratio 0.23 to 0.25; 0.24 is the middle of it.
  t.register_blocked_fma_factor = 0.24;
  return t;
}

Problem gemm_rowsum(int64_t M, int64_t N, int64_t K, const F32Target& target) {
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
  if (target.isa == "avx2") {
    gemm.variants.push_back({"avx2-vec-n", {{"B", Axis::Col}}, {{"C", Axis::Col}}, fma, {}, false});
    gemm.variants.push_back({"avx2-vec-m", {{"A", Axis::Row}}, {{"C", Axis::Row}}, fma, {}, false});
  }
  if (M % 6 == 0 && N % target.tile_cols == 0) {  // the register-blocked kernel's shapes (6 rows by tile_cols columns)
    Variant packed{target.isa + "-packed-n", {{"B", Axis::Col}}, {{"C", Axis::Col}}, fma * target.register_blocked_fma_factor, {}, false};
    packed.requires_storage["B"] = Storage::Panel;
    packed.threadable = true;
    gemm.variants.push_back(packed);
  }
  Op rowsum{"rowsum", {"C"}, "R", {}};
  rowsum.variants.push_back({"reduce-vertical", {{"C", Axis::Row}}, {}, store_adds, {}, false});
  rowsum.variants.push_back({"reduce-horizontal", {{"C", Axis::Col}}, {},
                             store_adds + double(M) * target.hsum_instr_per_row, {}, false});
  p.ops = {gemm, rowsum};
  // The row sums the emitters produce: horizontal for the packed kernels, and VecM with its vertical sum. Other pairs
  // would be a plan with a repair the emitters do not perform (for example C transposed for a vertical sum after the
  // packed kernel), and they tie with the emitted plan at the smallest N.
  p.incompatible = {{"avx2-vec-n", "reduce-vertical"},
                    {"avx2-packed-n", "reduce-vertical"},
                    {"avx512-packed-n", "reduce-vertical"},
                    {"avx2-vec-m", "reduce-horizontal"}};
  return p;
}

}  // namespace nfcuop::layout
