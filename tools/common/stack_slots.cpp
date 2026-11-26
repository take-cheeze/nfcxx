// The worklist of stack_slots::analyze (see stack_slots.hpp).
#include "stack_slots.hpp"

#include <algorithm>
#include <deque>

namespace stack_slots {

Flow analyze(std::size_t entry, const Transfer &transfer, Order order) {
  Flow flow;
  std::deque<std::size_t> work;
  flow.at[entry] = State{};
  work.push_back(entry);
  while (!work.empty()) {
    std::size_t pc;
    if (order == Order::Lifo) {
      pc = work.back();
      work.pop_back();
    } else {
      pc = work.front();
      work.pop_front();
    }
    const State in = flow.at.at(pc);
    const Step step = transfer(pc, in);
    flow.max_depth = std::max(flow.max_depth, step.high);
    for (const Succ &s : step.succ) {
      auto it = flow.at.find(s.pc);
      if (it == flow.at.end()) {
        flow.max_depth = std::max(flow.max_depth, s.state.depth);
        flow.at.emplace(s.pc, s.state);
        work.push_back(s.pc);
      } else if (it->second != s.state) {
        flow.join = Join{it->second.depth != s.state.depth, s.pc, pc};
        return flow;
      }
    }
  }
  return flow;
}

}  // namespace stack_slots
