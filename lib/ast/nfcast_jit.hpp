// nfcast JIT, the machine-code tier for loops (docs/notes/ast.md, "JIT"). A hot `while`, `repeat` or integer `for` loop whose body is
// 64-bit integer arithmetic on locals is encoded to x86-64 in memory and taken over at the same points as the C tier's loops
// (tier_loop in nfcast_tier.cpp). Everything else is refused at compile time and stays with the interpreter (or the C tier).
// Off unless TierOptions::jit is set (the test driver takes --jit); off altogether on any host but x86-64 Linux.
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
  // Deopt (docs/notes/ast.md, "JIT"). Every local of the loop (a live-in or one it declares) is in bail_slots / bail_regs: when the
  // code stops at an operation it cannot finish, these are written back to the frame. Site k (1-based, the value run() returns) is the
  // statement or condition the operation is in: the interpreter runs that unit, which raises the error the operation raises.
  struct Site {
    Node* node = nullptr;
    bool stmt = false;  // a statement (exec), else an expression (eval)
  };
  std::vector<int> bail_slots, bail_regs;
  std::vector<Site> sites;
};

// The code of the loop LOOP, which is a `while`, `repeat` or numeric `for` (KIND: the TierLoopState::Kind it is entered with).
// Null with WHY set when the loop is not in the subset (docs/notes/ast.md, "JIT" lists it).
std::unique_ptr<Code> compile(Node* loop, int kind, std::string& why);

// The entry guard: every live-in holds an integer. Checked at every takeover; nothing runs unless it holds.
bool entry_ok(const Frame& f, const Code& c);

// Runs the code from the state ST (the state of a FOR_INT loop at the top of an iteration, see TierLoopState) with the guard holding.
// Returns 0 when the loop ran to its end, and writes the live-ins that the loop assigns back to the frame: the interpreter goes on
// after the loop. Returns k > 0 when the code stopped at an operation it cannot finish (site k, a zero divisor): every local of the
// loop is written back, and the caller must call resume() with k.
int run(Frame& f, const Code& c, const TierLoopState& st);

// Deopt: the interpreter runs the unit of site K, the statement or condition the code stopped in, on the frame. That unit raises the
// error its operation raises (the same message, at the same line); it is an error if the unit returns, and then this raises one too.
void resume(Frame& f, const Code& c, int k);

}  // namespace jit
}  // namespace nfcast
