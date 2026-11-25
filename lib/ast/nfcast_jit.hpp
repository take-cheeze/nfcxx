// nfcast JIT, the machine-code tier for loops (docs/notes/ast.md, "JIT"). A hot `while`, `repeat` or integer `for` loop whose body is
// 64-bit integer arithmetic on locals is encoded to x86-64 in memory and taken over at the same points as the C tier's loops
// (tier_loop in nfcast_tier.cpp). Everything else is refused at compile time and stays with the interpreter (or the C tier).
// Off unless TierOptions::jit is set (NFCAST_JIT=1 for the test drivers); off altogether on any host but x86-64 Linux.
#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "nfcast_tier.hpp"

namespace nfcast {

struct Frame;

namespace jit {

// True on x86-64 Linux, the hosts the encoder is written for. Elsewhere compile() refuses every loop with a reason saying so.
bool available();

// The machine code of one loop, with what its entry needs and what its end gives back.
struct Code {
  Code() = default;
  Code(const Code&) = delete;
  Code& operator=(const Code&) = delete;
  ~Code();
  void* mem = nullptr;       // the mapped code (read and execute, never writable at the same time)
  std::size_t size = 0;      // its length in bytes, a whole number of pages
  int (*fn)(std::int64_t* regs) = nullptr;  // runs the loop on REGS: one 64-bit word per register, filled by run()
  int kind = 0;              // the TierLoopState::Kind it was made for
  int nregs = 0;             // registers REGS has
  // A frame slot the loop reads or assigns without declaring it is a live-in: the frame must hold an integer in it at entry
  // (entry_ok), and it is loaded into its register. The live-ins the loop assigns are written back when it ends.
  std::vector<int> in_slots, in_regs;
  std::vector<int> out_slots, out_regs;
  int state_regs[3] = {-1, -1, -1};  // FOR_INT: the registers of the next value of the variable, the count, and the step
};

// The code of the loop LOOP, which is a `while`, `repeat` or numeric `for` (KIND: the TierLoopState::Kind it is entered with).
// Null with WHY set when the loop is not in the subset (docs/notes/ast.md, "JIT" lists it).
std::unique_ptr<Code> compile(Node* loop, int kind, std::string& why);

// The entry guard: every live-in holds an integer. Checked at every takeover; nothing runs unless it holds.
bool entry_ok(const Frame& f, const Code& c);

// Runs the code from the state ST (the state of a FOR_INT loop at the top of an iteration, see TierLoopState) with the guard holding,
// and writes the live-ins that the loop assigns back to the frame. The loop has ended when it returns: the interpreter goes on after it.
void run(Frame& f, const Code& c, const TierLoopState& st);

}  // namespace jit
}  // namespace nfcast
