// nfcast JIT, the machine-code tier for loops (docs/notes/ast.md, "JIT"). A hot `while`, `repeat` or integer `for` loop whose body is
// arithmetic on locals, integers and floats, is encoded to x86-64 in memory and taken over at the same points as the C tier's loops
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
  // Runs the loop on REGS (one 64-bit word per register, filled by run()) from ENTRY: 0 is the top of the loop, k > 0 the continuation of
  // deopt site k's unit (see Site). Returns 0 when the loop ran to its end, else the number of the site it stopped at.
  int (*fn)(std::int64_t* regs, int entry) = nullptr;
  int kind = 0;              // the TierLoopState::Kind it was made for
  int nregs = 0;             // registers REGS has
  std::vector<char> reg_float;  // per register: 1 when it holds a float (its IEEE double bits), 0 an integer
  std::vector<char> reg_tab;    // per register: 1 when it holds a table (its Table* word): a live-in table, never assigned by the loop
  // A frame slot the loop reads or assigns without declaring it is a live-in: the frame must hold a value of the type of its register
  // at entry (entry_ok: an integer, a float, or a table), and it is loaded into its register. The live-ins the loop assigns are written
  // back when it ends.
  std::vector<int> in_slots, in_regs;
  std::vector<int> out_slots, out_regs;
  int state_regs[3] = {-1, -1, -1};  // FOR_INT: the registers of the next value of the variable, the count, and the step; FOR_FLT: the
                                     // registers of the next value, the limit and the step (doubles)
  // Deopt (docs/notes/ast.md, "JIT"). When the code stops at an operation it cannot finish, the locals of the site are written back to
  // the frame (Site::bail_slots and bail_regs) and the code returns the site's number k (1-based). Then the interpreter runs the unit the
  // site is in on the frame (the statement or condition the operation is in), and:
  //  - RAISE: the unit raises the error of the operation (a zero divisor); the interpreter returns from it only by a bug;
  //  - STMT: the unit is a statement that completes (a table element that is read or written in the interpreter's way); the loop goes
  //    on at Site::entry, the statement after the unit;
  //  - COND: the unit is a condition; the loop goes on at Site::entry when it is true, at Site::entry_false when it is false.
  // Entries are numbered from 1 (Site::entry and entry_false are such numbers); run() re-enters the code with them.
  struct Site {
    enum Kind { RAISE = 0, STMT = 1, COND = 2 };
    Node* node = nullptr;
    int kind = RAISE;
    bool stmt = false;  // RAISE: the unit is a statement (exec), else an expression or condition (eval)
    int entry = 0, entry_false = 0;
    // The locals written back when the code stops here: every frame slot of the loop with its register, as the slot is at this point
    // of the loop (a slot the loop reuses in two blocks has one register per declaration; the live-ins are in every site). Table
    // registers are not written back: the frame holds the table.
    std::vector<int> bail_slots, bail_regs;
  };
  std::vector<Site> sites;
};

// The code of the loop LOOP, which is a `while`, `repeat` or numeric `for` (KIND: the TierLoopState::Kind it is entered with). The
// types of its live-ins are the types of their values in the frame F, now (the loop is compiled for them). Null with WHY set when the
// loop is not in the subset (docs/notes/ast.md, "JIT" lists it).
std::unique_ptr<Code> compile(Node* loop, int kind, const Frame& f, std::string& why);

// The entry guard: every live-in holds a value of its type (an integer, a float, or a table). Checked at every takeover; nothing runs
// unless it holds.
bool entry_ok(const Frame& f, const Code& c);

// Runs the code from the state ST (the state of a FOR_INT loop at the top of an iteration, see TierLoopState) with the guard holding,
// until the loop ends. Writes the live-ins that the loop assigns back to the frame: the interpreter goes on after the loop. Each deopt
// (see Code::Site) adds one to BAILOUTS, runs the unit of its site in the interpreter and goes on in the code. An error the interpreter
// raises in a unit (a zero divisor) leaves run() by the exception, as the interpreter's own would.
void run(Frame& f, const Code& c, const TierLoopState& st, std::uint64_t& bailouts);

}  // namespace jit
}  // namespace nfcast
