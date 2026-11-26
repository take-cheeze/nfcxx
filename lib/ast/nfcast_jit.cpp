// nfcast JIT: x86-64 machine code for the loops of the AST interpreter (docs/notes/ast.md, "JIT"). The loop is read through the
// tier's view of its nodes (tier_view), the same one the C tier lowers from, and only the subset listed in the notes is encoded:
// integers, + - * and unary minus, comparisons, and/or/not in conditions, if, while, repeat, numeric for loops with an integer step
// that is a constant (except the one that takes over the loop, whose step is run-time), break, and locals. Integer arithmetic wraps
// as the interpreter's does, so no operation can fail, and no run needs a bail-out: a `//`, `%`, `/`, `^` or bitwise operator, or
// anything else outside the subset, makes compile() refuse the loop.
//
// Registers. The machine code has one 64-bit word per local (and per hidden variable of a for loop) in an array REGS, whose address
// is in RBX (callee-saved, pushed at the entry). RAX, RCX and RDX are scratch; a binary operation of two compound operands evaluates
// its left operand, pushes it, evaluates the right one, and pops the left one into RAX (a constant or a local operand is read directly,
// with no push). There are no calls, no memory but REGS, and no allocation, so the
// code has no side effects: whatever the entry guard does not cover cannot be observed before the loop ends.
//
// Register allocation. The four most referenced words (weighted by loop depth) live in R12-R15 for the whole loop instead of in
// REGS. They are loaded from REGS at the entry (after the guard, which reads only the frame) and every exit of the loop goes through
// the epilogue, which stores back the live-ins the loop assigns before the callee-saved registers are restored. The loop has no
// other exit: no call, no bail-out, and no operation can fail. So the frame sees the words only at entry and at that write-back.
// The code is generated twice: once with every word in memory to count the references, then with the allocation.
#include "nfcast_jit.hpp"

#include <algorithm>
#include <cstring>
#include <initializer_list>
#include <map>
#include <set>

#include "nfcast_impl.hpp"

#if defined(__x86_64__) && defined(__linux__)
#include <sys/mman.h>
#include <unistd.h>
#define NFCAST_JIT_X64 1
#else
#define NFCAST_JIT_X64 0
#endif

namespace nfcast {
namespace jit {

bool available() { return NFCAST_JIT_X64 != 0; }

Code::~Code() {
#if NFCAST_JIT_X64
  if (mem) munmap(mem, size);
#endif
}

bool entry_ok(const Frame& f, const Code& c) {
  for (int slot : c.in_slots)
    if (f.base[slot].t != T_INT) return false;
  return true;
}

void run(Frame& f, const Code& c, const TierLoopState& st) {
  std::int64_t small[64] = {0};
  std::vector<std::int64_t> big;
  std::int64_t* R = small;
  if (c.nregs > 64) {
    big.assign(static_cast<std::size_t>(c.nregs), 0);
    R = big.data();
  }
  for (std::size_t k = 0; k < c.in_slots.size(); ++k) R[c.in_regs[k]] = f.base[c.in_slots[k]].i;
  if (c.kind == TierLoopState::FOR_INT) {
    R[c.state_regs[0]] = st.i;
    R[c.state_regs[1]] = static_cast<std::int64_t>(st.count);
    R[c.state_regs[2]] = st.step;
  }
  c.fn(R);
  for (std::size_t k = 0; k < c.out_slots.size(); ++k) f.base[c.out_slots[k]] = Value::integer(R[c.out_regs[k]]);
}

#if NFCAST_JIT_X64
namespace {

// ---- the encoder --------------------------------------------------------------------------------------------------------------------
enum { RAX = 0, RCX = 1, RDX = 2 };
// The condition codes of Jcc (0F 80+cc) and SETcc. Negating a condition flips the low bit: E/NE, L/GE, LE/G.
enum Cc { CC_E = 0x4, CC_NE = 0x5, CC_L = 0xC, CC_GE = 0xD, CC_LE = 0xE, CC_G = 0xF };

class Asm {
 public:
  std::vector<std::uint8_t> b;

  int label() {
    labels_.push_back(-1);
    return static_cast<int>(labels_.size()) - 1;
  }
  void bind(int l) { labels_[static_cast<std::size_t>(l)] = static_cast<long>(b.size()); }
  void jmp(int l) {
    b.push_back(0xE9);
    rel32(l);
  }
  void jcc(int cc, int l) {
    b.push_back(0x0F);
    b.push_back(static_cast<std::uint8_t>(0x80 | cc));
    rel32(l);
  }
  void push_rax() { b.push_back(0x50); }
  void pop_rax() { b.push_back(0x58); }
  // REG = word K and word K = REG (REG is RAX, RCX or RDX): a memory access in REGS, or a register move when K is allocated.
  void load(int reg, int k) {
    note(k);
    int p = phys_of(k);
    if (p >= 0) mov_rr(reg, p);
    else mem_op(0x8B, reg, k);
  }
  void store(int k, int reg) {
    note(k);
    int p = phys_of(k);
    if (p >= 0) mov_rr(p, reg);
    else mem_op(0x89, reg, k);
  }
  // The allocation: PHYS[k] is the register (R12-R15) word k lives in, or -1 for memory. The registers in use are saved at the entry.
  void set_phys(const std::vector<int>& phys) {
    phys_ = phys;
    saved_.clear();
    for (int p : phys)
      if (p >= 0 && std::find(saved_.begin(), saved_.end(), p) == saved_.end()) saved_.push_back(p);
    std::sort(saved_.begin(), saved_.end());
  }
  int phys_of(int k) const { return k >= 0 && k < static_cast<int>(phys_.size()) ? phys_[static_cast<std::size_t>(k)] : -1; }
  // The loop nesting of the code being emitted, and the references to each word weighted by it (the allocation's priorities).
  void enter_loop() { ++depth_; }
  void leave_loop() { --depth_; }
  const std::vector<long>& refs() const { return refs_; }
  // mov REG, V: the sign-extended imm32 form when V fits, else the imm64 one.
  void mov_imm(int reg, std::int64_t v) {
    if (v >= INT32_MIN && v <= INT32_MAX) {
      b.push_back(0x48);
      b.push_back(0xC7);
      b.push_back(static_cast<std::uint8_t>(0xC0 | reg));
      u32(static_cast<std::uint32_t>(v));
    } else {
      b.push_back(0x48);
      b.push_back(static_cast<std::uint8_t>(0xB8 | reg));
      u64(static_cast<std::uint64_t>(v));
    }
  }
  void add_rax_rcx() { op_rr(0x01, 0xC8); }   // add rax, rcx
  void sub_rax_rcx() { op_rr(0x29, 0xC8); }   // sub rax, rcx
  void imul_rax_rcx() { bytes({0x48, 0x0F, 0xAF, 0xC1}); }
  void neg_rax() { bytes({0x48, 0xF7, 0xD8}); }
  void mov_rcx_rax() { op_rr(0x89, 0xC1); }    // mov rcx, rax
  void cmp_rax_rcx() { op_rr(0x39, 0xC8); }    // cmp rax, rcx (flags of rax - rcx)
  void cmp_rax_0() { bytes({0x48, 0x83, 0xF8, 0x00}); }
  void sub_rax_1() { bytes({0x48, 0x83, 0xE8, 0x01}); }
  void xor_edx_edx() { bytes({0x31, 0xD2}); }
  void div_rcx() { bytes({0x48, 0xF7, 0xF1}); }  // unsigned rdx:rax / rcx, quotient in rax
  void prologue() {  // push rbx; mov rbx, rdi; push the registers in use; load every allocated word into its register
    bytes({0x53, 0x48, 0x89, 0xFB});
    for (int r : saved_) push_r(r);
    for (std::size_t k = 0; k < phys_.size(); ++k)
      if (phys_[k] >= 0) mem_op(0x8B, phys_[k], static_cast<int>(k));
  }
  // The write-back of an allocated word K to REGS (a word in memory is already there). The loop's exits call this, then epilogue().
  void spill(int k) {
    int p = phys_of(k);
    if (p >= 0) mem_op(0x89, p, k);
  }
  void epilogue() {  // pop the registers in use; pop rbx; xor eax, eax; ret
    for (std::size_t i = saved_.size(); i-- > 0;) pop_r(saved_[i]);
    bytes({0x5B, 0x31, 0xC0, 0xC3});
  }

  // Patches the rel32 fields; false when a label was used and never bound.
  bool finish() {
    for (const Fix& f : fixes_) {
      long target = labels_[static_cast<std::size_t>(f.label)];
      if (target < 0) return false;
      long rel = target - static_cast<long>(f.at + 4);
      for (int k = 0; k < 4; ++k) b[f.at + static_cast<std::size_t>(k)] = static_cast<std::uint8_t>((rel >> (8 * k)) & 0xFF);
    }
    return true;
  }

 private:
  struct Fix {
    std::size_t at;
    int label;
  };
  std::vector<long> labels_;
  std::vector<Fix> fixes_;
  std::vector<int> phys_;       // word -> register, see set_phys
  std::vector<int> saved_;      // the registers in use, ascending: saved at the entry, restored at the exit
  std::vector<long> refs_;      // word -> references (weighted by the loop depth) in the code emitted so far
  int depth_ = 0;

  void note(int k) {
    if (static_cast<std::size_t>(k) >= refs_.size()) refs_.resize(static_cast<std::size_t>(k) + 1, 0);
    refs_[static_cast<std::size_t>(k)] += 1L << (3 * depth_ < 40 ? 3 * depth_ : 40);
  }
  void push_r(int r) {
    if (r >= 8) b.push_back(0x41);
    b.push_back(static_cast<std::uint8_t>(0x50 | (r & 7)));
  }
  void pop_r(int r) {
    if (r >= 8) b.push_back(0x41);
    b.push_back(static_cast<std::uint8_t>(0x58 | (r & 7)));
  }
  // mov DST, SRC (64-bit, both registers; DST is RAX, RCX, RDX or R12-R15).
  void mov_rr(int dst, int src) {
    b.push_back(static_cast<std::uint8_t>(0x48 | ((src >> 3) << 2) | (dst >> 3)));
    b.push_back(0x89);
    b.push_back(static_cast<std::uint8_t>(0xC0 | ((src & 7) << 3) | (dst & 7)));
  }
  void bytes(std::initializer_list<std::uint8_t> xs) { b.insert(b.end(), xs.begin(), xs.end()); }
  void op_rr(std::uint8_t opc, std::uint8_t modrm) { bytes({0x48, opc, modrm}); }
  void u32(std::uint32_t x) {
    for (int k = 0; k < 4; ++k) b.push_back(static_cast<std::uint8_t>((x >> (8 * k)) & 0xFF));
  }
  void u64(std::uint64_t x) {
    for (int k = 0; k < 8; ++k) b.push_back(static_cast<std::uint8_t>((x >> (8 * k)) & 0xFF));
  }
  void rel32(int l) {
    fixes_.push_back(Fix{b.size(), l});
    u32(0);
  }
  // OPC with REG (RAX..R15) and [rbx + 8 * k]: REX.W (and REX.R for R8-R15), the opcode, then ModRM (mod 10, rm 011 = rbx) and the
  // displacement. OPC 8B is a load into REG, 89 a store from REG.
  void mem_op(std::uint8_t opc, int reg, int k) {
    b.push_back(static_cast<std::uint8_t>(0x48 | ((reg >> 3) << 2)));
    b.push_back(opc);
    b.push_back(static_cast<std::uint8_t>(0x80 | ((reg & 7) << 3) | 0x03));
    u32(static_cast<std::uint32_t>(8 * k));
  }
};

// ---- the code generator -------------------------------------------------------------------------------------------------------
// Walks the loop through the tier's view. Every function returns false once the loop is refused (`why` says why; the first reason
// is kept).
struct Gen {
  Asm a;
  bool ok = true;
  std::string why;
  int nregs = 0;
  std::set<int> declared;       // slots a local of the loop declares (anywhere in it): not live-ins
  std::set<int> seen;           // of those, the ones whose declaration has been passed in the text
  std::map<int, int> reg_of;    // frame slot -> register
  std::vector<int> in_slots, in_regs;  // the live-ins, in the order they were first used
  std::set<int> written;        // the live-ins the loop assigns
  std::vector<int> breaks;      // the exits of the enclosing loops

  bool fail(const std::string& m) {
    if (ok) {
      ok = false;
      why = m;
    }
    return false;
  }

  // The register of a local the loop declares (declared just now).
  int declare_reg(int slot) {
    auto it = reg_of.find(slot);
    if (it != reg_of.end()) return it->second;
    int r = nregs++;
    reg_of[slot] = r;
    return r;
  }

  // The register of a frame slot the loop uses: a local of the loop (its declaration must have been passed in the text, so that the
  // slot is not one that an outer local shares) or a live-in (loaded at entry, and written back when assigned).
  int slot_reg(int slot, bool write) {
    if (declared.count(slot)) {
      if (!seen.count(slot)) {
        fail("a local of the loop used before its declaration (a slot shared with an outer local)");
        return -1;
      }
      return reg_of[slot];
    }
    auto it = reg_of.find(slot);
    if (it == reg_of.end()) {
      int r = nregs++;
      reg_of[slot] = r;
      in_slots.push_back(slot);
      in_regs.push_back(r);
      it = reg_of.find(slot);
    }
    if (write) written.insert(slot);
    return it->second;
  }

  // Every slot a local of the loop declares, anywhere in it.
  void collect(Node* n) {
    if (!n) return;
    TierView v;
    tier_view(n, v);
    if (v.kind == TierView::K_DECL || v.kind == TierView::K_FOR)
      for (int s : v.slots) declared.insert(s);
    for (Node* k : v.kids) collect(k);
    for (Node* k : v.blocks) collect(k);
    collect(v.els);
    collect(v.cond);
  }

  // Leaves the value of the integer expression N in RAX.
  bool expr(Node* n) {
    if (!n) return fail("an expression that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_CONST:
        if (v.k.t != T_INT) return fail("a constant that is not an integer");
        a.mov_imm(RAX, v.k.i);
        return true;
      case TierView::K_LOCAL: {
        if (v.flag) return fail("a local captured by a closure");
        int r = slot_reg(v.slot, false);
        if (r < 0) return false;
        a.load(RAX, r);
        return true;
      }
      case TierView::K_ARITH: {
        if (v.op != AR_ADD && v.op != AR_SUB && v.op != AR_MUL)
          return fail("an operator outside the subset (division, modulo, power or a bitwise operator needs a run-time check)");
        if (!binary(v.kids[0], v.kids[1])) return false;
        if (v.op == AR_ADD) a.add_rax_rcx();
        else if (v.op == AR_SUB) a.sub_rax_rcx();
        else a.imul_rax_rcx();
        return true;
      }
      case TierView::K_UNARY:
        if (v.op != AR_UNM) return fail("an operator outside the subset (not, length, bitwise not)");
        if (!expr(v.kids[0])) return false;
        a.neg_rax();
        return true;
      case TierView::K_CMP:
      case TierView::K_EQ:
      case TierView::K_AND:
      case TierView::K_OR:
        return fail("a comparison or a logical operator used as a value (only conditions are compiled)");
      case TierView::K_CALL:
        return fail("a call");
      case TierView::K_UPVAL:
      case TierView::K_GLOBAL:
        return fail("an upvalue or a global");
      default:
        return fail("an expression outside the subset");
    }
  }

  // A leaf is an integer constant or a local that is not captured: reading it runs no code that can change anything or fail, so its
  // read may come before or after the other operand's evaluation (the expressions of the subset assign nothing).
  bool leaf(Node* n) {
    TierView v;
    tier_view(n, v);
    return (v.kind == TierView::K_CONST && v.k.t == T_INT) || (v.kind == TierView::K_LOCAL && !v.flag);
  }
  // Loads the leaf N into REG (RAX or RCX).
  bool leaf_into(Node* n, int reg) {
    TierView v;
    tier_view(n, v);
    if (v.kind == TierView::K_CONST) {
      a.mov_imm(reg, v.k.i);
      return true;
    }
    int r = slot_reg(v.slot, false);
    if (r < 0) return false;
    a.load(reg, r);
    return true;
  }

  // RAX = left, RCX = right. A leaf on either side needs no push: a leaf on the right is loaded into RCX after the left is evaluated,
  // and a leaf on the left is loaded into RAX after the right is evaluated (its value moved to RCX first). Only two compound operands
  // keep the left value on the machine stack while the right one is computed.
  bool binary(Node* l, Node* r) {
    if (leaf(r)) {
      if (!expr(l)) return false;
      return leaf_into(r, RCX);
    }
    if (leaf(l)) {
      if (!expr(r)) return false;
      a.mov_rcx_rax();
      return leaf_into(l, RAX);
    }
    if (!expr(l)) return false;
    a.push_rax();
    if (!expr(r)) return false;
    a.mov_rcx_rax();
    a.pop_rax();
    return true;
  }

  // Jumps to TARGET when the condition N has the truth value JUMP_IF (Lua's: nil and false are false, everything else true).
  bool branch(Node* n, bool jump_if, int target) {
    if (!n) return fail("a condition that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_CMP: {
        static const int cc[] = {CC_E, CC_NE, CC_L, CC_LE, CC_G, CC_GE};  // CMP_EQ, CMP_NE, CMP_LT, CMP_LE, CMP_GT, CMP_GE
        if (v.op < 0 || v.op > 5) return fail("a comparison outside the subset");
        return compare(v.kids, cc[v.op], jump_if, target);
      }
      case TierView::K_EQ:
        return compare(v.kids, v.flag ? CC_NE : CC_E, jump_if, target);
      case TierView::K_AND:
        if (!jump_if) return branch(v.kids[0], false, target) && branch(v.kids[1], false, target);
        {
          int skip = a.label();
          if (!branch(v.kids[0], false, skip) || !branch(v.kids[1], true, target)) return false;
          a.bind(skip);
          return true;
        }
      case TierView::K_OR:
        if (jump_if) return branch(v.kids[0], true, target) && branch(v.kids[1], true, target);
        {
          int skip = a.label();
          if (!branch(v.kids[0], true, skip) || !branch(v.kids[1], false, target)) return false;
          a.bind(skip);
          return true;
        }
      case TierView::K_UNARY:
        if (v.op == OPX_NOT) return branch(v.kids[0], !jump_if, target);
        break;  // a negation: a number
      case TierView::K_CONST: {
        bool truthy = !(v.k.t == T_NIL || v.k.t == T_FALSE);
        if (truthy == jump_if) a.jmp(target);
        return true;
      }
      default:
        break;
    }
    // A number (a local, an arithmetic result) is always true: its value is computed (it cannot fail) and the jump is unconditional.
    if (!expr(n)) return false;
    if (jump_if) a.jmp(target);
    return true;
  }

  bool compare(const std::vector<Node*>& kids, int cc, bool jump_if, int target) {
    if (kids.size() != 2) return fail("a comparison without two operands");
    if (!binary(kids[0], kids[1])) return false;
    a.cmp_rax_rcx();
    a.jcc(jump_if ? cc : (cc ^ 1), target);
    return true;
  }

  bool stmt(Node* n) {
    if (!n) return fail("a statement that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_BLOCK:
        for (Node* k : v.kids)
          if (!stmt(k)) return false;
        return true;
      case TierView::K_DECL:
        return decl(v);
      case TierView::K_ASSIGN:
        return assign(v);
      case TierView::K_IF:
        return conditional(v);
      case TierView::K_WHILE:
        return while_loop(v);
      case TierView::K_REPEAT:
        return repeat_loop(v);
      case TierView::K_FOR:
        return for_loop(v);
      case TierView::K_BREAK:
        if (breaks.empty()) return fail("a break outside a loop");
        a.jmp(breaks.back());
        return true;
      case TierView::K_RETURN:
        return fail("a return inside the loop");
      case TierView::K_CALL:
        return fail("a call as a statement");
      default:
        return fail("a statement outside the subset");
    }
  }

  bool decl(const TierView& v) {
    if (v.captured) return fail("a local captured by a closure");
    if (v.multi_last || v.kids.size() != v.slots.size()) return fail("a local declared without one integer value");
    if (v.slots.size() == 1) {  // one local: its value goes straight to its register
      if (!expr(v.kids[0])) return false;
      a.store(declare_reg(v.slots[0]), RAX);
      seen.insert(v.slots[0]);
      return true;
    }
    for (Node* k : v.kids) {
      if (!expr(k)) return false;
      a.push_rax();
    }
    for (std::size_t i = v.slots.size(); i-- > 0;) {
      a.pop_rax();
      a.store(declare_reg(v.slots[i]), RAX);
    }
    for (int s : v.slots) seen.insert(s);
    return true;
  }

  bool assign(const TierView& v) {
    if (v.captured) return fail("an assignment to a captured local, an upvalue, a global or a field");
    for (int t : v.tkinds)
      if (t != TierView::T_LOCAL) return fail("an assignment to a captured local, an upvalue, a global or a field");
    if (v.multi_last || v.kids.size() != v.slots.size()) return fail("an assignment of other than one value per target");
    if (v.slots.size() == 1) {  // one target: its value goes straight to its word
      if (!expr(v.kids[0])) return false;
      int r = slot_reg(v.slots[0], true);
      if (r < 0) return false;
      a.store(r, RAX);
      return true;
    }
    for (Node* k : v.kids) {
      if (!expr(k)) return false;
      a.push_rax();
    }
    for (std::size_t i = v.slots.size(); i-- > 0;) {
      a.pop_rax();
      int r = slot_reg(v.slots[i], true);
      if (r < 0) return false;
      a.store(r, RAX);
    }
    return true;
  }

  bool conditional(const TierView& v) {
    int end = a.label();
    for (std::size_t i = 0; i < v.kids.size(); ++i) {
      int next = a.label();
      if (!branch(v.kids[i], false, next) || !stmt(v.blocks[i])) return false;
      a.jmp(end);
      a.bind(next);
    }
    if (v.els && !stmt(v.els)) return false;
    a.bind(end);
    return true;
  }

  bool while_loop(const TierView& v) {
    int top = a.label(), exit = a.label();
    a.enter_loop();
    a.bind(top);
    if (!branch(v.cond, false, exit)) return false;
    breaks.push_back(exit);
    if (!stmt(v.blocks[0])) return false;
    breaks.pop_back();
    a.jmp(top);
    a.bind(exit);
    a.leave_loop();
    return true;
  }

  bool repeat_loop(const TierView& v) {
    int top = a.label(), exit = a.label();
    a.enter_loop();
    a.bind(top);
    breaks.push_back(exit);
    if (!stmt(v.blocks[0])) return false;
    breaks.pop_back();
    if (!branch(v.cond, true, exit)) return false;
    a.jmp(top);
    a.bind(exit);
    a.leave_loop();
    return true;
  }

  // The count and the variable of an integer loop (Lua 5.4's forprep and nfcr_forcount: the iterations after the first one).
  // HI is the next value, HC the count, HS the step (a register) or the constant STEP_CONST when HS < 0.
  void loop_tail(int hi, int hc, int hs, std::int64_t step_const, int top, int done) {
    a.load(RAX, hc);
    a.cmp_rax_0();
    a.jcc(CC_E, done);  // count == 0: this was the last iteration
    a.sub_rax_1();
    a.store(hc, RAX);
    a.load(RAX, hi);
    if (hs >= 0) a.load(RCX, hs);
    else a.mov_imm(RCX, step_const);
    a.add_rax_rcx();
    a.store(hi, RAX);
    a.jmp(top);
  }

  // A numeric `for` inside the loop: the start and the limit are evaluated once; the step is a constant (not zero).
  bool for_loop(const TierView& v) {
    if (v.captured) return fail("a loop variable captured by a closure");
    std::int64_t step = 1;
    if (v.kids.size() == 3 && v.kids[2]) {
      TierView sv;
      tier_view(v.kids[2], sv);
      if (sv.kind != TierView::K_CONST || sv.k.t != T_INT) return fail("a for loop whose step is not an integer constant");
      step = sv.k.i;
      if (step == 0) return fail("a for loop with a step of zero (an error the interpreter reports)");
    }
    int hi = nregs++, hl = nregs++, hc = nregs++;
    if (!expr(v.kids[0])) return false;
    a.store(hi, RAX);
    if (!expr(v.kids[1])) return false;
    a.store(hl, RAX);
    int done = a.label(), top = a.label();
    a.load(RAX, hi);
    a.load(RCX, hl);
    a.cmp_rax_rcx();
    a.jcc(step > 0 ? CC_G : CC_L, done);  // start beyond the limit: the loop does not run
    if (step > 0) {
      a.load(RAX, hl);
      a.load(RCX, hi);
      a.sub_rax_rcx();  // limit - start (unsigned, as the interpreter's)
      if (step != 1) {
        a.mov_imm(RCX, step);
        a.xor_edx_edx();
        a.div_rcx();
      }
    } else {
      a.load(RAX, hi);
      a.load(RCX, hl);
      a.sub_rax_rcx();  // start - limit
      a.mov_imm(RCX, static_cast<std::int64_t>(static_cast<std::uint64_t>(-(step + 1)) + 1u));
      a.xor_edx_edx();
      a.div_rcx();
    }
    a.store(hc, RAX);
    int var = declare_reg(v.slots[0]);
    seen.insert(v.slots[0]);
    a.enter_loop();
    a.bind(top);
    a.load(RAX, hi);
    a.store(var, RAX);
    breaks.push_back(done);
    if (!stmt(v.blocks[0])) return false;
    breaks.pop_back();
    loop_tail(hi, hc, -1, step, top, done);
    a.bind(done);
    a.leave_loop();
    return true;
  }
};

// The loop itself: a `while`, a `repeat`, or the numeric `for` the takeover starts in (its state comes in the registers).
bool top_level(Gen& g, Node* loop, int kind, Code& code) {
  TierView v;
  tier_view(loop, v);
  g.collect(loop);
  g.a.prologue();
  if (kind == TierLoopState::FOR_INT) {
    if (v.kind != TierView::K_FOR) return g.fail("a loop that is not a numeric for");
    if (v.captured) return g.fail("a loop variable captured by a closure");
    int hi = g.nregs++, hc = g.nregs++, hs = g.nregs++;
    code.state_regs[0] = hi;
    code.state_regs[1] = hc;
    code.state_regs[2] = hs;
    int var = g.declare_reg(v.slots[0]);
    g.seen.insert(v.slots[0]);
    int done = g.a.label(), top = g.a.label();
    g.a.enter_loop();
    g.a.bind(top);
    g.a.load(RAX, hi);
    g.a.store(var, RAX);
    g.breaks.push_back(done);
    if (!g.stmt(v.blocks[0])) return false;
    g.breaks.pop_back();
    g.loop_tail(hi, hc, hs, 0, top, done);
    g.a.bind(done);
    g.a.leave_loop();
  } else if (kind == TierLoopState::WHILE && v.kind == TierView::K_WHILE) {
    if (!g.while_loop(v)) return false;
  } else if (kind == TierLoopState::REPEAT && v.kind == TierView::K_REPEAT) {
    if (!g.repeat_loop(v)) return false;
  } else {
    return g.fail("a loop kind the JIT does not take over");
  }
  // The write-back: every exit of the loop (the end of the loop, its breaks) comes here, and the live-ins it assigns go back to REGS
  // (run() copies them to the frame). A word in memory is already there; an allocated one is stored from its register.
  for (std::size_t k = 0; k < g.in_slots.size(); ++k)
    if (g.written.count(g.in_slots[k])) g.a.spill(g.in_regs[k]);
  g.a.epilogue();
  return g.ok;
}

}  // namespace
#endif  // NFCAST_JIT_X64

std::unique_ptr<Code> compile(Node* loop, int kind, std::string& why) {
#if NFCAST_JIT_X64
  if (kind == TierLoopState::FOR_FLT) {
    why = "a float for loop (the JIT compiles integer loops only)";
    return nullptr;
  }
  // Register allocation: the first pass generates the loop with every word in memory and counts the references to each word (weighted
  // by loop depth, so the control variables, referenced on every iteration, rank first). The four most referenced words get R12-R15
  // (callee-saved) and the second pass generates the code with them. The allocation does not change what is in the subset, so the
  // second pass accepts the loop when the first did.
  const int kFirstAllocReg = 12, kAllocRegs = 4;  // R12..R15
  Gen g1;
  Code c1;
  c1.kind = kind;
  if (!top_level(g1, loop, kind, c1) || !g1.a.finish()) {
    why = g1.ok ? "internal: an unbound label" : g1.why;
    return nullptr;
  }
  std::vector<long> refs = g1.a.refs();
  refs.resize(static_cast<std::size_t>(g1.nregs), 0);
  std::vector<int> order(static_cast<std::size_t>(g1.nregs));
  for (std::size_t k = 0; k < order.size(); ++k) order[k] = static_cast<int>(k);
  std::stable_sort(order.begin(), order.end(), [&refs](int x, int y) { return refs[static_cast<std::size_t>(x)] > refs[static_cast<std::size_t>(y)]; });
  std::vector<int> phys(static_cast<std::size_t>(g1.nregs), -1);
  int next = 0;
  for (int k : order) {
    if (next == kAllocRegs || refs[static_cast<std::size_t>(k)] == 0) break;
    phys[static_cast<std::size_t>(k)] = kFirstAllocReg + next++;
  }

  Gen g;
  g.a.set_phys(phys);
  std::unique_ptr<Code> code(new Code());
  code->kind = kind;
  if (!top_level(g, loop, kind, *code) || !g.a.finish()) {
    why = g.ok ? "internal: an unbound label" : g.why;
    return nullptr;
  }
  for (std::size_t k = 0; k < g.in_slots.size(); ++k) {
    code->in_slots.push_back(g.in_slots[k]);
    code->in_regs.push_back(g.in_regs[k]);
    if (g.written.count(g.in_slots[k])) {
      code->out_slots.push_back(g.in_slots[k]);
      code->out_regs.push_back(g.in_regs[k]);
    }
  }
  code->nregs = g.nregs;
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) page = 4096;
  std::size_t bytes = g.a.b.size();
  std::size_t size = (bytes + static_cast<std::size_t>(page) - 1) / static_cast<std::size_t>(page) * static_cast<std::size_t>(page);
  void* mem = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mem == MAP_FAILED) {
    why = "mmap failed";
    return nullptr;
  }
  std::memcpy(mem, g.a.b.data(), bytes);
  if (mprotect(mem, size, PROT_READ | PROT_EXEC) != 0) {
    munmap(mem, size);
    why = "mprotect (read and execute) failed";
    return nullptr;
  }
  code->mem = mem;
  code->size = size;
  code->fn = reinterpret_cast<int (*)(std::int64_t*)>(reinterpret_cast<std::uintptr_t>(mem));
  return code;
#else
  (void)loop;
  (void)kind;
  why = "the JIT is not available on this host (it is written for x86-64 Linux)";
  return nullptr;
#endif
}

}  // namespace jit
}  // namespace nfcast
