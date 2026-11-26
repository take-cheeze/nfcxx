// The operand stack of a stack-machine bytecode, as a static fact: the depth before each instruction, and the frame slot of
// each stack position. The producers (tools/yarvbc, tools/cpython, tools/mpy) each decode their own bytecode and give the
// dataflow a transfer function; nothing here knows an opcode.
//
// The walk starts at an entry state and follows each instruction's successors. A state is the depth plus the producer's
// facts about the entries (ctx: the kinds or origins of the stack entries, or the try blocks open there). The state of an
// instruction is set on its first arrival; a later arrival must carry the same state, or the walk stops and reports the join
// (Flow::join), and the producer refuses or throws with its own message.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <vector>

namespace stack_slots {

// The state on entry to an instruction along one path.
struct State {
  std::size_t depth = 0;          // the operand-stack depth
  std::vector<std::int64_t> ctx;  // the producer's facts about the entries, compared where paths join
  bool operator==(const State &o) const { return depth == o.depth && ctx == o.ctx; }
  bool operator!=(const State &o) const { return !(*this == o); }
};

// An edge out of an instruction: the instruction at pc is entered with `state`.
struct Succ {
  std::size_t pc;
  State state;
};

// What an instruction does on one path: its successors, in the order the producer wants them checked (a jump before the
// fall-through, say), and `high`, the deepest the operand stack gets while the instruction runs (at least its depth on entry).
struct Step {
  std::vector<Succ> succ;
  std::size_t high = 0;
};

// Lowers one reached instruction from its state on entry. The producer decodes the instruction at pc, and throws its own
// errors (an unknown opcode, a stack underflow, a jump that lands between instructions).
using Transfer = std::function<Step(std::size_t pc, const State &in)>;

// The order the reached instructions are visited in: a stack (Lifo) or a queue (Fifo). It only decides which of two joins
// that both disagree is reported first.
enum class Order { Lifo, Fifo };

// The first join where two paths disagree. `pc` is the instruction the paths reach, and `from` the instruction whose edge
// arrives second. depth_differs is set when the depths differ; otherwise the depths agree and the ctx does not.
struct Join {
  bool depth_differs = false;
  std::size_t pc = 0;
  std::size_t from = 0;
};

struct Flow {
  std::map<std::size_t, State> at;  // the state on entry to each instruction the entry reaches
  std::size_t max_depth = 0;        // the deepest the operand stack gets anywhere reached (an entry's depth or a step's high)
  std::optional<Join> join;         // set when the walk stopped at a join that disagrees; `at` is then partial
};

// Walks the instructions reachable from `entry` (with the empty stack and the empty ctx), calling transfer once per reached
// instruction. The walk stops at the first disagreeing join.
Flow analyze(std::size_t entry, const Transfer &transfer, Order order = Order::Lifo);

// The frame slot of stack position `pos` when the operand stack follows `base` slots (a frame's locals, say).
inline std::size_t slot(std::size_t base, std::size_t pos) { return base + pos; }

}  // namespace stack_slots
