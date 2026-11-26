// nfcast JIT, the machine-code tier for loops (docs/notes/ast.md, "JIT"). A hot `while`, `repeat` or integer `for` loop whose body is
// arithmetic on locals, integers and floats, is encoded to x86-64 in memory and taken over at the same points as the C tier's loops
// (tier_loop in nfcast_tier.cpp). Everything else is refused at compile time and stays with the interpreter (or the C tier).
// Calls (docs/notes/ast.md, "The calls"): a call of a global, an upvalue or a local of the loop's function, as a statement or as a
// number the code uses, is made by the interpreter's own call path through a helper; the callee's error leaves the loop as the
// interpreter's does, and a result of another kind than the code expects finishes the statement in the interpreter.
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
struct TierLoopState;

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
  std::vector<char> reg_float;  // per register: 1 when it holds a float (its IEEE double bits), 0 an integer
  // A frame slot the loop reads or assigns without declaring it is a live-in: the frame must hold a value of the type of its register
  // at entry (entry_ok: an integer, or a float), and it is loaded into its register. The live-ins the loop assigns are written back
  // when it ends.
  std::vector<int> in_slots, in_regs;
  std::vector<int> out_slots, out_regs;
  int state_regs[3] = {-1, -1, -1};  // FOR_INT: the registers of the next value of the variable, the count, and the step; FOR_FLT: the
                                     // registers of the next value, the limit and the step (doubles)
  int ctx_reg = -1;       // the word that holds the address of the run's context (run() stores it; the calls use it), or -1
  Node* until = nullptr;  // REPEAT: its condition, evaluated when the interpreter finishes an iteration
  // Deopt (docs/notes/ast.md, "JIT"). When the code stops at an operation it cannot finish, the locals of the site are written back to
  // the frame (Site::bail_slots and bail_regs). Site k (1-based, the value run() returns) is the statement or condition the operation
  // is in: the interpreter runs that unit, which raises the error the operation raises.
  // A call (kind CALL) is a site too: its locals are written back, and run() then raises the callee's error, or finishes the statement
  // the call is in with the call's value (the chain) and the rest of the iteration.
  struct Site {
    enum Kind { DEOPT, CALL } kind = DEOPT;
    Node* node = nullptr;  // DEOPT: the unit; CALL: the call node
    bool stmt = false;     // a statement (exec), else an expression (eval)
    // CALL: the statements the interpreter runs after the code stopped at the call, in order: the innermost statement the call is in
    // (its call returns the value, see CallReplay), the rest of its block, then the rest of each enclosing block up to the loop's body.
    std::vector<Node*> chain;
    // The locals written back when the code stops here: every frame slot of the loop with its register, as the slot is at this point
    // of the loop (a slot the loop reuses in two blocks has one register per declaration; the live-ins are in every site).
    std::vector<int> bail_slots, bail_regs;
  };
  std::vector<Site> sites;
};

// What run() returns when a call's result was not the kind the code expected and the interpreter finished the iteration: the loop
// goes on in the interpreter from the state it was given (kRunGo), or it ended there (kRunStop: a break, or the end of a repeat).
constexpr int kRunGo = -1;
constexpr int kRunStop = -2;

// The code of the loop LOOP, which is a `while`, `repeat` or numeric `for` (KIND: the TierLoopState::Kind it is entered with). The
// types of its live-ins are the types of their values in the frame F, now (the loop is compiled for them). Null with WHY set when the
// loop is not in the subset (docs/notes/ast.md, "JIT" lists it).
std::unique_ptr<Code> compile(Node* loop, int kind, const Frame& f, std::string& why);

// The entry guard: every live-in holds a value of its type (an integer or a float). Checked at every takeover; nothing runs unless it holds.
bool entry_ok(const Frame& f, const Code& c);

// Runs the code from the state ST (the state of a FOR_INT loop at the top of an iteration, see TierLoopState) with the guard holding.
// Returns 0 when the loop ran to its end, and writes the live-ins that the loop assigns back to the frame: the interpreter goes on
// after the loop. Returns k > 0 when the code stopped at an operation it cannot finish (site k, a zero divisor): every local of the
// loop is written back, and the caller must call resume() with k. Returns kRunGo or kRunStop when a call's result was not the kind the
// code expected: the interpreter finished that iteration, and ST is the state of the next one (kRunGo). A callee's error is raised from
// here, once the code has left, as the interpreter raises it.
int run(Frame& f, const Code& c, TierLoopState& st);

// Deopt: the interpreter runs the unit of site K, the statement or condition the code stopped in, on the frame. That unit raises the
// error its operation raises (the same message, at the same line); it is an error if the unit returns, and then this raises one too.
void resume(Frame& f, const Code& c, int k);

}  // namespace jit
}  // namespace nfcast
