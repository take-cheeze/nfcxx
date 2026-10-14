// Static placement of buffers in one arena (stage 4, docs/notes/uop.md): the planner the C renderer uses for its intermediates.
//
// Ported from onnxsim's activation memory planner (memory_planning.h and memory_planning.cpp of onnxsim's C++ sources, where
// ComputeActivationMemoryPlan does this in its "Pass 2"). Ported: the liveness test (two buffers may share bytes only when their
// [start, end] intervals do not overlap, the ends counted, so a buffer written at step i never shares with one read at step i),
// and the placement, largest buffer first (ties by name), into the smallest gap between the ranges of the already placed
// buffers whose intervals overlap it, else after all of them. Not ported: onnxsim's in-place aliasing passes, which union an
// operator's output with its input; a fused loop nest reads its inputs at other indices than it writes, so it cannot use them.
// Sizes are rounded up to `align`, so every offset is a multiple of `align`.
#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace nfcuop {

// One buffer to place: `size` bytes, live at every step from `start` to `end`, both included.
struct ArenaTensor {
  std::string name;  // unique among the tensors given to plan_arena
  int64_t size = 0;
  int start = 0;
  int end = 0;
};

struct ArenaPlan {
  std::map<std::string, int64_t> offsets;  // name -> byte offset within the arena (a multiple of the align argument)
  int64_t arena_bytes = 0;                 // the size the arena needs: the highest offset + size (0 with nothing to place)
};

// Throws Error on a duplicate name, a size below 1, start > end, or an align below 1.
ArenaPlan plan_arena(const std::vector<ArenaTensor>& tensors, int64_t align);

}  // namespace nfcuop
