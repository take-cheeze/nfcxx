// nfcuop arena planner. See nfcuop_arena.hpp for what is ported from onnxsim and what is not.
#include "nfcuop_arena.hpp"

#include <algorithm>
#include <set>
#include <utility>

#include "nfcuop.hpp"

namespace nfcuop {

namespace {

// Two buffers may share bytes only when their intervals do not overlap. The ends are included: a buffer whose last use is step i
// and one that is written at step i overlap.
bool disjoint(int a_start, int a_end, int b_start, int b_end) { return a_end < b_start || b_end < a_start; }

struct Placed {
  int start = 0, end = 0;
  int64_t lo = 0, hi = 0;  // the bytes it occupies: [lo, hi)
};

}  // namespace

ArenaPlan plan_arena(const std::vector<ArenaTensor>& tensors, int64_t align) {
  if (align < 1) throw Error("plan_arena: the alignment must be at least 1");
  std::set<std::string> names;
  std::vector<ArenaTensor> ts = tensors;
  for (ArenaTensor& t : ts) {
    if (!names.insert(t.name).second) throw Error("plan_arena: two tensors are named " + t.name);
    if (t.size < 1 || t.start > t.end) throw Error("plan_arena: " + t.name + " has an empty size or an empty interval");
    if (t.size > INT64_MAX - align) throw Error("plan_arena: " + t.name + " is too large");
    t.size = (t.size + align - 1) / align * align;
  }
  // largest first, ties by name: the greedy order of onnxsim's planner
  std::sort(ts.begin(), ts.end(), [](const ArenaTensor& a, const ArenaTensor& b) {
    if (a.size != b.size) return a.size > b.size;
    return a.name < b.name;
  });

  ArenaPlan plan;
  std::vector<Placed> placed;
  for (const ArenaTensor& t : ts) {
    // the ranges of the placed tensors whose intervals overlap this one: the bytes it must avoid
    std::vector<std::pair<int64_t, int64_t>> blocking;
    for (const Placed& p : placed) {
      if (!disjoint(t.start, t.end, p.start, p.end)) blocking.push_back({p.lo, p.hi});
    }
    std::sort(blocking.begin(), blocking.end());

    // the smallest gap that fits, else the end of the last blocker
    int64_t best_offset = -1, best_gap = -1, cursor = 0;
    for (const auto& b : blocking) {
      const int64_t gap = b.first - cursor;
      if (gap >= t.size && (best_gap < 0 || gap < best_gap)) {
        best_offset = cursor;
        best_gap = gap;
      }
      cursor = std::max(cursor, b.second);
    }
    if (best_offset < 0) best_offset = cursor;

    plan.offsets[t.name] = best_offset;
    placed.push_back(Placed{t.start, t.end, best_offset, best_offset + t.size});
    plan.arena_bytes = std::max(plan.arena_bytes, best_offset + t.size);
  }
  return plan;
}

}  // namespace nfcuop
