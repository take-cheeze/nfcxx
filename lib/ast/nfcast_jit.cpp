// nfcast JIT: x86-64 machine code for the loops of the AST interpreter (docs/notes/ast.md, "JIT"). The loop is read through the
// tier's view of its nodes (tier_view), the same one the C tier lowers from, and only the subset listed in the notes is encoded:
// integers and floats (the float operators + - * / // % ^ and unary minus, the comparisons of two floats and of an integer with a float
// as the interpreter does them, and the mixed arithmetic of an integer and a float), integer `//` and `%` (floor division and modulo,
// as the interpreter's), the bitwise operators & | ~ (binary xor), << and >> and unary ~ on integers, comparisons of two integers,
// and/or/not in conditions, if, while, repeat, numeric for loops with a constant step (integer or float, not zero; an integer loop
// takes a float limit as the interpreter clips it, and a loop with a float start or step is a float loop), break, and locals. Integer arithmetic wraps as the interpreter's does, and the bitwise operators never fail. The one
// operation that can fail is integer `//` or `%` by zero: the code then stops, writes its locals back, and the interpreter raises the
// error (the deopt, see run() and resume()). Everything else outside the subset makes compile() refuse the loop.
//
// Types. Every local (and every hidden variable of a for loop) has one static type for the whole loop: an integer or a float. The
// type of a live-in is the type of its value when the loop is compiled (compile() reads the frame), and the entry guard checks it at
// every takeover; a local the loop declares takes the type of its first value, and an assignment of the other type is refused.
// The word of a float is its IEEE double bit pattern; every operation of a float is SSE2 on it.
//
// Registers. The machine code has one 64-bit word per local (and per hidden variable of a for loop) in an array REGS, whose address
// is in RBX (callee-saved, pushed at the entry). RAX, RCX and RDX are scratch; a binary operation of two compound operands evaluates
// its left operand, pushes it, evaluates the right one, and pops the left one into RAX (a constant or a local operand is read directly,
// with no push). There is no memory but REGS, and no allocation. The calls are to the interpreter's own functions, through the
// addresses of the wrappers below (jit_pow, jit_fmod, jit_fidiv, the comparisons of an integer with a float, jit_eq, jit_forlimit):
// the code keeps no value in a caller-saved register across them, and the stack is aligned for each. Otherwise the code has no side
// effects: whatever the entry guard does not cover cannot be observed before the loop ends.
//
// Register allocation. The four most referenced words (weighted by loop depth) live in R12-R15 for the whole loop instead of in
// REGS. They are loaded from REGS at the entry (after the guard, which reads only the frame) and every exit of the loop goes through
// the epilogue, which stores back the live-ins the loop assigns before the callee-saved registers are restored. The loop has no
// other exit: no operation can fail except the zero divisor, which deopts. So the frame sees the words only at entry and at that write-back.
// The code is generated twice: once with every word in memory to count the references, then with the allocation.
#include "nfcast_jit.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <exception>
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

// A word of REGS as the frame's value: an integer, or a float from its bits.
static Value word_value(bool flt, std::int64_t w) {
  if (!flt) return Value::integer(w);
  double d;
  std::memcpy(&d, &w, sizeof d);
  return Value::number(d);
}

// The word of a live-in: its integer, or the bits of its float (the guard has checked the type).
static std::int64_t value_word(const Value& v) {
  if (v.t != T_FLT) return v.i;
  std::int64_t w;
  std::memcpy(&w, &v.d, sizeof w);
  return w;
}

bool entry_ok(const Frame& f, const Code& c) {
  for (std::size_t k = 0; k < c.in_slots.size(); ++k) {
    auto want = c.reg_float[static_cast<std::size_t>(c.in_regs[k])] ? T_FLT : T_INT;
    if (f.base[c.in_slots[k]].t != want) return false;
  }
  return true;
}

// The context of one run of the code (run() keeps it on its stack and stores its address in Code::ctx_reg): the frame; the error of a
// callee, which the code has left with; the value of a call whose kind was not the one the code expected.
struct JitCtx {
  Frame* f;
  std::exception_ptr err;
  Value cached;
};

// What the call helper returns (in RAX and RDX): the word of the result, and a status: 0 the result is the kind the code expects (or
// no kind is expected), 1 the callee raised an error (in the context), 2 the result is of another kind (in the context).
struct JitRet {
  std::int64_t w;
  std::int64_t st;
};

constexpr int kMaxCallArgs = 16;

// The call of the call node SITE by the compiled code: the N arguments are the words in ARGS (the bits of a float, for the arguments
// whose bit is set in FLAGS >> 8, and an integer for the others), the function is called as the interpreter calls it (jit_call_value).
// FLAGS & 3 is the kind the code expects of the result: 0 none, 1 an integer, 2 a float.
JitRet jit_call_helper(JitCtx* c, Node* site, const std::int64_t* args, std::int64_t n, std::int64_t flags) {
  Value av[kMaxCallArgs];
  try {
    for (std::int64_t k = 0; k < n; ++k) {
      if ((flags >> (8 + k)) & 1) {
        double d;
        std::memcpy(&d, &args[k], sizeof d);
        av[k] = Value::number(d);
      } else {
        av[k] = Value::integer(args[k]);
      }
    }
    Value r = jit_call_value(*c->f, site, av, static_cast<int>(n));
    int want = static_cast<int>(flags & 3);
    if (want == 0) return JitRet{0, 0};
    if (want == 1 && r.t == T_INT) return JitRet{r.i, 0};
    if (want == 2 && r.t == T_FLT) {
      std::int64_t w;
      std::memcpy(&w, &r.d, sizeof w);
      return JitRet{w, 0};
    }
    c->cached = r;
    return JitRet{0, 2};
  } catch (...) {  // never unwind through the machine code: the error is raised by run(), once the code has left
    c->err = std::current_exception();
    return JitRet{0, 1};
  }
}

double word_double(std::int64_t w) {
  double d;
  std::memcpy(&d, &w, sizeof d);
  return d;
}

// The code stopped at the call S.node, whose result was not the kind the code expected (ctx.cached). The statement the call is in is
// finished by the interpreter with the call returning that value (CallReplay, which is in the frame F only), then the rest of the
// iteration (S.chain). Then the loop goes on in the interpreter from the next iteration: its state is that of the iteration after the
// one the call is in, as the code has it (for a for loop, from the registers the stub spilled).
int finish_call(Frame& f, const Code& c, const Code::Site& s, JitCtx& ctx, const std::int64_t* R, TierLoopState& st) {
  State& S = *f.S;
  ++S.stats.jit_call_mismatches;  // counted here, so that an error the replay raises is counted too
  TierLoopState next = st;
  bool last = false;  // the iteration the call is in is the last one of a for loop
  if (c.kind == TierLoopState::FOR_INT) {
    std::int64_t hi = R[c.state_regs[0]], hs = R[c.state_regs[2]];
    std::uint64_t hc = static_cast<std::uint64_t>(R[c.state_regs[1]]);
    last = hc == 0;  // NumForNode: `if (count-- == 0) break;`
    next.i = static_cast<std::int64_t>(static_cast<std::uint64_t>(hi) + static_cast<std::uint64_t>(hs));
    next.count = hc - 1;
    next.step = hs;
  } else if (c.kind == TierLoopState::FOR_FLT) {
    double idx = word_double(R[c.state_regs[0]]), limit = word_double(R[c.state_regs[1]]), step = word_double(R[c.state_regs[2]]);
    double nx = idx + step;  // the loop's increment, then its test after an iteration
    last = !(0 < step ? nx <= limit : limit <= nx);
    next.d = nx;
    next.limit = limit;
    next.dstep = step;
  }
  if (S.top + 2 >= S.stack_end) S.rt_error("stack overflow");
  Value* saved = S.top;
  *S.top++ = ctx.cached;  // rooted on the stack while the interpreter holds it
  CallReplay rp{&f, ctx.cached};
  Node* call = jit_current(s.node);
  jit_set_replay(call, &rp);
  bool stop = false;
  try {
    for (Node* n : s.chain)
      if (jit_current(n)->exec(f) == C_BREAK) {
        stop = true;
        break;
      }
    if (!stop && c.kind == TierLoopState::REPEAT && c.until && jit_current(c.until)->eval(f).truthy()) stop = true;
  } catch (...) {
    jit_set_replay(call, nullptr);
    S.top = saved;
    throw;
  }
  jit_set_replay(call, nullptr);
  S.top = saved;
  if (stop) return kRunStop;
  // The end of the iteration, as the interpreter's loop node does it: the for loops check their count or their test after the
  // safe point of the edge (a float loop has it before the test, an integer loop only when it goes on), a while loop has it too.
  if (c.kind == TierLoopState::FOR_INT) {
    if (last) return kRunStop;
    st = next;
    loop_edge(f);
    return kRunGo;
  }
  if (c.kind == TierLoopState::FOR_FLT) {
    loop_edge(f);
    if (last) return kRunStop;
    st = next;
    return kRunGo;
  }
  loop_edge(f);
  return kRunGo;
}

int run(Frame& f, const Code& c, TierLoopState& st) {
  std::int64_t small[64] = {0};
  std::vector<std::int64_t> big;
  std::int64_t* R = small;
  if (c.nregs > 64) {
    big.assign(static_cast<std::size_t>(c.nregs), 0);
    R = big.data();
  }
  JitCtx ctx{&f, nullptr, Value()};
  if (c.ctx_reg >= 0) R[c.ctx_reg] = static_cast<std::int64_t>(reinterpret_cast<std::intptr_t>(&ctx));
  for (std::size_t k = 0; k < c.in_slots.size(); ++k) R[c.in_regs[k]] = value_word(f.base[c.in_slots[k]]);
  if (c.kind == TierLoopState::FOR_INT) {
    R[c.state_regs[0]] = st.i;
    R[c.state_regs[1]] = static_cast<std::int64_t>(st.count);
    R[c.state_regs[2]] = st.step;
  } else if (c.kind == TierLoopState::FOR_FLT) {
    R[c.state_regs[0]] = value_word(Value::number(st.d));
    R[c.state_regs[1]] = value_word(Value::number(st.limit));
    R[c.state_regs[2]] = value_word(Value::number(st.dstep));
  }
  int site = c.fn(R);
  if (site != 0) {  // a deopt or a call: the locals of the site go back to the frame, as they are at the operation
    const Code::Site& s = c.sites[static_cast<std::size_t>(site - 1)];
    for (std::size_t k = 0; k < s.bail_slots.size(); ++k) {
      std::size_t r = static_cast<std::size_t>(s.bail_regs[k]);
      f.base[s.bail_slots[k]] = word_value(c.reg_float[r] != 0, R[s.bail_regs[k]]);
    }
    if (s.kind == Code::Site::DEOPT) return site;
    if (ctx.err) std::rethrow_exception(ctx.err);  // the callee's error: the loop is left, as the interpreter leaves it
    return finish_call(f, c, s, ctx, R, st);
  }
  for (std::size_t k = 0; k < c.out_slots.size(); ++k) {
    std::size_t r = static_cast<std::size_t>(c.out_regs[k]);
    f.base[c.out_slots[k]] = word_value(c.reg_float[r] != 0, R[c.out_regs[k]]);
  }
  return 0;
}

void resume(Frame& f, const Code& c, int k) {
  const Code::Site& s = c.sites[static_cast<std::size_t>(k - 1)];
  // The unit is pure up to the operation that stopped the code (an expression, or a statement whose stores come after all its
  // operands), so the interpreter's evaluation of it from the written-back state reaches the same zero divisor and raises the same
  // error, with the same line (the operation sets the line before it raises).
  if (s.stmt) s.node->exec(f);
  else s.node->eval(f);
  f.S->rt_error("internal: the machine code stopped at an operation that did not raise its error");
}

#if NFCAST_JIT_X64
namespace {

// ---- the encoder --------------------------------------------------------------------------------------------------------------
enum { RAX = 0, RCX = 1, RDX = 2, RSP = 4, RSI = 6, RDI = 7, R8 = 8 };
// The condition codes of Jcc (0F 80+cc) and SETcc. Negating a condition flips the low bit: E/NE, L/GE, LE/G.
enum Cc {
  CC_B = 0x2, CC_AE = 0x3, CC_E = 0x4, CC_NE = 0x5, CC_BE = 0x6, CC_A = 0x7, CC_S = 0x8, CC_NS = 0x9, CC_P = 0xA,
  CC_L = 0xC, CC_GE = 0xD, CC_LE = 0xE, CC_G = 0xF
};

// The calls the code makes: each is a function of the interpreter, the one it computes the operation with, so the results are its
// results bit for bit. The double functions take their operands in xmm0 and xmm1 and return in xmm0.
double jit_pow(double x, double y) { return flt_pow(x, y); }
// The float `%` and `//` (flt_mod, and the floor of the quotient as arith_numbers computes it).
double jit_fmod(double x, double y) { return flt_mod(x, y); }
double jit_fidiv(double x, double y) { return std::floor(x / y); }
// The comparisons of an integer with a float, the interpreter's own (nfcast_tier_rt.h): the integer is the first argument (RDI), the
// float the second (XMM0), whichever side of the operator each of them is on. Results are 0 or 1.
std::int64_t jit_lt_if(std::int64_t i, double f) { return nfcr_lt_if(i, f); }  // i < f
std::int64_t jit_lt_fi(std::int64_t i, double f) { return nfcr_lt_fi(f, i); }  // f < i
std::int64_t jit_le_if(std::int64_t i, double f) { return nfcr_le_if(i, f); }  // i <= f
std::int64_t jit_le_fi(std::int64_t i, double f) { return nfcr_le_fi(f, i); }  // f <= i
std::int64_t jit_eq(std::int64_t i, double f) { return raw_equal(Value::integer(i), Value::number(f)) ? 1 : 0; }
// The limit of an integer numeric for loop with a float limit (nfcr_forlimit, as the interpreter's loop clips it): the limit, and RUNS
// = 0 when the loop does not run at all (the limit is beyond the range on the side the step moves away from).
struct JitLimit {
  std::int64_t limit;
  std::int64_t runs;
};
JitLimit jit_forlimit(double fl, std::int64_t step) {
  JitLimit r{0, 0};
  r.runs = nfcr_forlimit(fl, step, &r.limit);
  return r;
}

std::int64_t bits_of(double d) {
  std::int64_t w;
  std::memcpy(&w, &d, sizeof w);
  return w;
}

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
  void push_rax() {
    b.push_back(0x50);
    ++pushes_;
  }
  void pop_rax() {
    b.push_back(0x58);
    --pushes_;
  }
  void pop_rcx() {
    b.push_back(0x59);
    --pushes_;
  }
  // The stack space of the arguments of a call: N words below rsp, counted as pushes (a deopt drops them, the alignment counts them).
  void reserve(int n) {
    bytes({0x48, 0x81, 0xEC});  // sub rsp, imm32
    u32(static_cast<std::uint32_t>(8 * n));
    pushes_ += n;
  }
  void release(int n) {
    bytes({0x48, 0x81, 0xC4});  // add rsp, imm32
    u32(static_cast<std::uint32_t>(8 * n));
    pushes_ -= n;
  }
  // mov [rsp + 8 * K], RAX: argument K of the reserved area.
  void store_arg(int k) {
    bytes({0x48, 0x89, 0x84, 0x24});  // mov [rsp + disp32], rax
    u32(static_cast<std::uint32_t>(8 * k));
  }
  // The values pushed by the code emitted so far and not yet popped: a deopt drops them before it leaves the loop.
  int pushes() const { return pushes_; }
  // The registers the prologue pushed (see set_phys): with the pushes, they decide the alignment of the stack for a call.
  int saved_count() const { return static_cast<int>(saved_.size()); }
  void add_rsp(int n) {  // add rsp, 8 * n
    bytes({0x48, 0x81, 0xC4});
    u32(static_cast<std::uint32_t>(8 * n));
  }
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
  void mov_imm(int reg, std::int64_t v) {  // REX.B for R8-R15 (the flags of a call are in R8)
    if (v >= INT32_MIN && v <= INT32_MAX) {
      b.push_back(static_cast<std::uint8_t>(0x48 | (reg >> 3)));
      b.push_back(0xC7);
      b.push_back(static_cast<std::uint8_t>(0xC0 | (reg & 7)));
      u32(static_cast<std::uint32_t>(v));
    } else {
      b.push_back(static_cast<std::uint8_t>(0x48 | (reg >> 3)));
      b.push_back(static_cast<std::uint8_t>(0xB8 | (reg & 7)));
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
  void and_rax_rcx() { op_rr(0x21, 0xC8); }   // and rax, rcx
  void or_rax_rcx() { op_rr(0x09, 0xC8); }    // or rax, rcx
  void xor_rax_rcx() { op_rr(0x31, 0xC8); }   // xor rax, rcx
  void not_rax() { bytes({0x48, 0xF7, 0xD0}); }  // not rax (the bitwise ~)
  // RAX = RAX shifted by the count in RCX, as the interpreter's shift_left (nfcr_shl): a count of 64 or more, or of -64 or less,
  // gives 0, a positive count shifts left, a negative one shifts right logically. RIGHT: the count is negated first (a >> b is
  // a << -b, with the negation wrapping as the interpreter's 0 - b does). Uses RAX and RCX only.
  void shift_rax_rcx(bool right) {
    int zero = label(), neg = label(), done = label();
    if (right) neg_rcx();
    bytes({0x48, 0x83, 0xF9, 0x40});  // cmp rcx, 64
    jcc(CC_GE, zero);
    bytes({0x48, 0x83, 0xF9, 0xC0});  // cmp rcx, -64
    jcc(CC_LE, zero);
    bytes({0x48, 0x85, 0xC9});        // test rcx, rcx
    jcc(CC_S, neg);
    bytes({0x48, 0xD3, 0xE0});        // shl rax, cl
    jmp(done);
    bind(neg);
    neg_rcx();
    bytes({0x48, 0xD3, 0xE8});        // shr rax, cl
    jmp(done);
    bind(zero);
    bytes({0x31, 0xC0});              // xor eax, eax
    bind(done);
  }
  void neg_rcx() { bytes({0x48, 0xF7, 0xD9}); }  // neg rcx
  void xor_edx_edx() { bytes({0x31, 0xD2}); }
  void div_rcx() { bytes({0x48, 0xF7, 0xF1}); }  // unsigned rdx:rax / rcx, quotient in rax
  // Floor division and modulo (Gen::floordiv): the signed forms and the tests they use.
  void test_rcx_rcx() { bytes({0x48, 0x85, 0xC9}); }
  void test_rax_rax() { bytes({0x48, 0x85, 0xC0}); }
  void test_rdx_rdx() { bytes({0x48, 0x85, 0xD2}); }
  void cmp_rcx_m1() { bytes({0x48, 0x83, 0xF9, 0xFF}); }  // cmp rcx, -1
  void xor_eax_eax() { bytes({0x31, 0xC0}); }
  void cqo() { bytes({0x48, 0x99}); }                      // rdx = the sign of rax
  void idiv_rcx() { bytes({0x48, 0xF7, 0xF9}); }           // signed rdx:rax / rcx: quotient in rax, remainder in rdx
  void xor_rdx_rcx() { bytes({0x48, 0x31, 0xCA}); }
  void mov_rdx_rax() { bytes({0x48, 0x89, 0xC2}); }
  void mov_rax_rdx() { bytes({0x48, 0x89, 0xD0}); }
  void mov_eax_imm(std::uint32_t v) {  // mov eax, imm32 (zero-extends)
    b.push_back(0xB8);
    u32(v);
  }
  // ---- floats (SSE2): the operands are in xmm0 and xmm1, the bits of a float in RAX or RCX ----
  void movq_x_r(int x, int r) { bytes({0x66, 0x48, 0x0F, 0x6E, modrm(3, x, r)}); }   // movq xmmX, r64
  void movq_r_x(int r, int x) { bytes({0x66, 0x48, 0x0F, 0x7E, modrm(3, x, r)}); }   // movq r64, xmmX
  void cvtsi2sd(int x, int r) { bytes({0xF2, 0x48, 0x0F, 0x2A, modrm(3, x, r)}); }   // the integer r64 as a double
  void sd_op(std::uint8_t opc, int dst, int src) { bytes({0xF2, 0x0F, opc, modrm(3, dst, src)}); }  // addsd 58, mulsd 59, subsd 5C, divsd 5E
  void ucomisd(int x, int y) { bytes({0x66, 0x0F, 0x2E, modrm(3, x, y)}); }        // flags of xmmX against xmmY
  void btc_rax_63() { bytes({0x48, 0x0F, 0xBA, 0xF8, 0x3F}); }                     // flip the sign bit (the unary minus of a float)
  // A call of the absolute address FN (through RAX, which holds nothing the caller needs: the operands are in xmm0 and xmm1).
  void call_abs(std::uintptr_t fn) {
    mov_imm(RAX, static_cast<std::int64_t>(fn));
    bytes({0xFF, 0xD0});  // call rax
  }
  void mov_rr_pub(int dst, int src) { mov_rr(dst, src); }  // mov DST, SRC (64-bit)
  void zero_x(int x) { bytes({0x0F, 0x57, modrm(3, x, x)}); }  // xorps xmmX, xmmX: +0.0 in xmmX
  void sub_rsp_8() { bytes({0x48, 0x83, 0xEC, 0x08}); }
  void add_rsp_8() { bytes({0x48, 0x83, 0xC4, 0x08}); }
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
  void epilogue() {  // a normal exit: eax = 0 (no deopt), then the restore below
    xor_eax_eax();
    restore_ret();
  }
  void restore_ret() {  // pop the registers in use; pop rbx; ret (EAX is the result: 0, or the deopt site)
    for (std::size_t i = saved_.size(); i-- > 0;) pop_r(saved_[i]);
    bytes({0x5B, 0xC3});
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
  int pushes_ = 0;              // see pushes()

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
  static std::uint8_t modrm(int mod, int reg, int rm) { return static_cast<std::uint8_t>((mod << 6) | ((reg & 7) << 3) | (rm & 7)); }
  void bytes(std::initializer_list<std::uint8_t> xs) { b.insert(b.end(), xs.begin(), xs.end()); }
  void op_rr(std::uint8_t opc, std::uint8_t modrm_byte) { bytes({0x48, opc, modrm_byte}); }
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

// The type of a register or a value: an integer, or a float (the bits in the word).
enum { TY_INT = 0, TY_FLT = 1, TY_NONE = -1 };

// ---- the code generator -------------------------------------------------------------------------------------------------------
// Walks the loop through the tier's view. Every function returns false (or TY_NONE) once the loop is refused (`why` says why; the
// first reason is kept).
struct Gen {
  Asm a;
  bool ok = true;
  std::string why;
  int nregs = 0;
  std::vector<char> flt;        // per register: 1 when it holds a float (see Code::reg_float)
  const Frame* fr = nullptr;    // the frame the loop is compiled in: the types of the live-ins are the types of their values
  std::set<int> declared;       // slots a local of the loop declares (anywhere in it): not live-ins
  std::set<int> seen;           // of those, the ones whose declaration has been passed in the text
  std::map<int, int> reg_of;    // frame slot -> register
  std::vector<int> in_slots, in_regs;  // the live-ins, in the order they were first used
  std::set<int> written;        // the live-ins the loop assigns
  std::vector<int> breaks;      // the exits of the enclosing loops
  // The deopt (see Code::Site). Each zero divisor jumps to the stub of its site, bound at the end of top_level, which writes the
  // site's locals back and returns the site. UNITS are the statements and conditions being generated, innermost last; SITES[k - 1] is
  // the unit of the operation that leaves with k in EAX, and STUBS[k - 1] the label of its stub.
  std::vector<Code::Site> units;
  std::vector<bool> unit_called;  // per unit: a call was emitted in it (a division after it could not be deopted: see zero_check)
  std::vector<Code::Site> sites;
  std::vector<int> stubs;
  // The calls (docs/notes/ast.md, "The calls"). LEVELS are the blocks being generated, innermost last: the statements of each (KIDS),
  // the one being generated (IDX), and the calls in it so far (one statement has at most one call). A call that stops the code is
  // finished by the interpreter from the statement it is in, so it needs the rest of each block, which these give.
  struct Level {
    const std::vector<Node*>* kids;
    std::size_t idx;
    int calls;
  };
  std::vector<Level> levels;
  int inner_loops = 0;          // loops entered inside the loop being compiled (their statements are not in the subset for calls)
  int args_depth = 0;           // the arguments of a call are generated (no call may be among them)
  int ctx_word = -1;            // the word that holds the address of the run's context (Code::ctx_reg), made by the first call
  std::set<int> callee_slots;   // the frame slots used as the function of a call: never a register
  static constexpr int WANT_DISCARD = 2;  // call_expr: the result is not used

  static Code::Site unit(Node* n, bool stmt) {
    Code::Site s;
    s.node = n;
    s.stmt = stmt;
    return s;
  }

  void push_unit(Node* n, bool stmt) {
    units.push_back(unit(n, stmt));
    unit_called.push_back(false);
  }
  void pop_unit() {
    units.pop_back();
    unit_called.pop_back();
  }

  bool fail(const std::string& m) {
    if (ok) {
      ok = false;
      why = m;
    }
    return false;
  }
  int failt(const std::string& m) {
    fail(m);
    return TY_NONE;
  }

  int new_reg(bool is_float) {
    flt.push_back(is_float ? 1 : 0);
    return nregs++;
  }

  // The register of a local the loop declares, of type TY (declared just now). The frame slot of a local may be shared with another
  // local of the loop in a block that does not overlap (the parser reuses slots), so a declaration of the other type gets a register of
  // its own, and reg_of then maps the slot to it: a name in the text refers to the latest declaration before it.
  int declare_reg(int slot, int ty) {
    auto it = reg_of.find(slot);
    if (it != reg_of.end() && (flt[static_cast<std::size_t>(it->second)] != 0) == (ty == TY_FLT)) return it->second;
    int r = new_reg(ty == TY_FLT);
    reg_of[slot] = r;
    return r;
  }

  // The type of a live-in: the type of its value in the frame when the loop is compiled (an integer for anything but a float).
  bool entry_float(int slot) const { return fr && fr->base[slot].t == T_FLT; }

  // The register of a frame slot the loop uses: a local of the loop (its declaration must have been passed in the text, so that the
  // slot is not one that an outer local shares) or a live-in (loaded at entry, and written back when assigned).
  int slot_reg(int slot, bool write) {
    if (callee_slots.count(slot)) {
      fail("a local used as a function and as a number");
      return -1;
    }
    if (declared.count(slot)) {
      if (!seen.count(slot)) {
        fail("a local of the loop used before its declaration (a slot shared with an outer local)");
        return -1;
      }
      return reg_of[slot];
    }
    auto it = reg_of.find(slot);
    if (it == reg_of.end()) {
      int r = new_reg(entry_float(slot));
      reg_of[slot] = r;
      in_slots.push_back(slot);
      in_regs.push_back(r);
      it = reg_of.find(slot);
    }
    if (write) written.insert(slot);
    return it->second;
  }

  bool is_flt(int r) const { return flt[static_cast<std::size_t>(r)] != 0; }

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

  // Leaves the value of the numeric expression N in RAX (the bits of a float) and returns its type.
  // EXPECT is the kind the code expects of a call's result (TY_INT or TY_FLT: the context of the value); other expressions ignore it.
  int expr(Node* n, int expect = TY_NONE) {
    if (!n) return failt("an expression that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_CONST:
        if (v.k.t == T_INT) {
          a.mov_imm(RAX, v.k.i);
          return TY_INT;
        }
        if (v.k.t == T_FLT) {
          a.mov_imm(RAX, bits_of(v.k.d));
          return TY_FLT;
        }
        return failt("a constant that is not a number");
      case TierView::K_LOCAL: {
        if (v.flag) return failt("a local captured by a closure");
        int r = slot_reg(v.slot, false);
        if (r < 0) return TY_NONE;
        a.load(RAX, r);
        return is_flt(r) ? TY_FLT : TY_INT;
      }
      case TierView::K_ARITH:
        return arith(v);
      case TierView::K_UNARY: {
        if (v.op != AR_BNOT && v.op != AR_UNM) return failt("an operator outside the subset (not, length)");
        int t = expr(v.kids[0]);
        if (t == TY_NONE) return TY_NONE;
        if (v.op == AR_BNOT) {
          if (t != TY_INT) return failt("a bitwise operator on a float");
          a.not_rax();
          return TY_INT;
        }
        if (t == TY_FLT) a.btc_rax_63();  // the sign bit: -x for every float, NaN included (as the interpreter's -x)
        else a.neg_rax();
        return t;
      }
      case TierView::K_CMP:
      case TierView::K_EQ:
      case TierView::K_AND:
      case TierView::K_OR:
        return failt("a comparison or a logical operator used as a value (only conditions are compiled)");
      case TierView::K_CALL:
        if (expect == TY_NONE) return failt("a call whose result kind is not known here (it is not an operand or a value of a local)");
        return call_expr(n, expect);
      case TierView::K_UPVAL:
      case TierView::K_GLOBAL:
        return failt("an upvalue or a global");
      default:
        return failt("an expression outside the subset");
    }
  }

  // An arithmetic operation. The operands are numbers (integers or floats); an integer operand of a float operation is converted to
  // a double first, as the interpreter does (arith_numbers). `/` and `^` always give a float.
  int arith(const TierView& v) {
    switch (v.op) {
      case AR_ADD: case AR_SUB: case AR_MUL: case AR_DIV: case AR_POW: case AR_IDIV: case AR_MOD:
      case AR_BAND: case AR_BOR: case AR_BXOR: case AR_SHL: case AR_SHR:
        break;
      default:
        return failt("an operator outside the subset");
    }
    int tl = TY_NONE, tr = TY_NONE;
    if (!binary(v.kids[0], v.kids[1], tl, tr)) return TY_NONE;
    bool ints = tl == TY_INT && tr == TY_INT;
    switch (v.op) {
      case AR_DIV:  // x / y: a float division (a zero divisor gives inf, -inf or nan, no error)
        to_xmm(tl, tr);
        a.sd_op(0x5E, 0, 1);  // divsd xmm0, xmm1
        a.movq_r_x(RAX, 0);
        return TY_FLT;
      case AR_POW:  // x ^ y: the call of pow (the interpreter's flt_pow)
        to_xmm(tl, tr);
        call_dbl2(reinterpret_cast<std::uintptr_t>(&jit_pow));
        return TY_FLT;
      case AR_ADD: case AR_SUB: case AR_MUL:
        if (!ints) {
          to_xmm(tl, tr);
          a.sd_op(v.op == AR_ADD ? 0x58 : v.op == AR_SUB ? 0x5C : 0x59, 0, 1);  // addsd, subsd, mulsd
          a.movq_r_x(RAX, 0);
          return TY_FLT;
        }
        if (v.op == AR_ADD) a.add_rax_rcx();
        else if (v.op == AR_SUB) a.sub_rax_rcx();
        else a.imul_rax_rcx();
        return TY_INT;
      case AR_IDIV: case AR_MOD:
        if (!ints) {  // a float floor division or modulo: the interpreter's functions (no error for a zero divisor)
          to_xmm(tl, tr);
          call_dbl2(reinterpret_cast<std::uintptr_t>(v.op == AR_MOD ? &jit_fmod : &jit_fidiv));
          return TY_FLT;
        }
        floordiv(v.op == AR_MOD);
        return TY_INT;
      default:  // the bitwise operators: integers only (a float with an integer value is refused as well)
        if (!ints) return failt("a bitwise operator on a float");
        if (v.op == AR_BAND) a.and_rax_rcx();
        else if (v.op == AR_BOR) a.or_rax_rcx();
        else if (v.op == AR_BXOR) a.xor_rax_rcx();
        else a.shift_rax_rcx(v.op == AR_SHR);
        return TY_INT;
    }
  }

  // XMM0 = RAX and XMM1 = RCX as doubles: an integer is converted (cvtsi2sd, rounded as the C conversion), a float is moved.
  void to_xmm(int tl, int tr) {
    if (tl == TY_INT) a.cvtsi2sd(0, RAX);
    else a.movq_x_r(0, RAX);
    if (tr == TY_INT) a.cvtsi2sd(1, RCX);
    else a.movq_x_r(1, RCX);
  }

  // A call of the interpreter's function FN with the stack aligned for it. The arguments are in the registers the C ABI takes them
  // from (RDI, XMM0, XMM1), and nothing is kept in a caller-saved register across it: the pushed values are in memory, and RBX and
  // R12-R15 are callee-saved. The result is in RAX or XMM0, as the function returns it.
  void call_c(std::uintptr_t fn) {
    bool odd = (a.saved_count() + a.pushes()) % 2 == 1;  // rsp is 16-aligned at the call when the pushes that are live sum to even
    if (odd) a.sub_rsp_8();
    a.call_abs(fn);
    if (odd) a.add_rsp_8();
  }
  // A double function of two operands (xmm0, xmm1): RAX = its result, as bits.
  void call_dbl2(std::uintptr_t fn) {
    call_c(fn);
    a.movq_r_x(RAX, 0);
  }

  // A leaf is an integer or a float constant, or a local that is not captured: reading it runs no code that can change anything or
  // fail, so its read may come before or after the other operand's evaluation (the expressions of the subset assign nothing).
  bool leaf(Node* n) {
    TierView v;
    tier_view(n, v);
    return (v.kind == TierView::K_CONST && (v.k.t == T_INT || v.k.t == T_FLT)) || (v.kind == TierView::K_LOCAL && !v.flag);
  }
  // Loads the leaf N into REG (RAX or RCX) and returns its type.
  int leaf_into(Node* n, int reg) {
    TierView v;
    tier_view(n, v);
    if (v.kind == TierView::K_CONST) {
      if (v.k.t == T_FLT) {
        a.mov_imm(reg, bits_of(v.k.d));
        return TY_FLT;
      }
      a.mov_imm(reg, v.k.i);
      return TY_INT;
    }
    int r = slot_reg(v.slot, false);
    if (r < 0) return TY_NONE;
    a.load(reg, r);
    return is_flt(r) ? TY_FLT : TY_INT;
  }

  // RAX = left, RCX = right (their types in TL and TR). A leaf on either side needs no push: a leaf on the right is loaded into RCX
  // after the left is evaluated, and a leaf on the left is loaded into RAX after the right is evaluated (its value moved to RCX
  // first). Only two compound operands keep the left value on the machine stack while the right one is computed.
  bool is_call(Node* n) {
    TierView v;
    tier_view(n, v);
    return v.kind == TierView::K_CALL;
  }

  bool binary(Node* l, Node* r, int& tl, int& tr) {
    bool lc = is_call(l), rc = is_call(r);
    if (lc && rc) return fail("two calls in one operation");
    if (rc) {  // the call is the right operand: the left one is computed first, and the call expects its kind
      tl = expr(l);
      if (tl == TY_NONE) return false;
      a.push_rax();
      tr = expr(r, tl);
      if (tr == TY_NONE) return false;
      a.mov_rcx_rax();
      a.pop_rax();
      return true;
    }
    if (lc) {  // the call is the left operand: the right one (which has no call) is computed first, and the call expects its kind
      tr = expr(r);
      if (tr == TY_NONE) return false;
      a.push_rax();
      tl = expr(l, tr);
      if (tl == TY_NONE) return false;
      a.pop_rcx();
      return true;
    }
    if (leaf(r)) {
      tl = expr(l);
      if (tl == TY_NONE) return false;
      tr = leaf_into(r, RCX);
      return tr != TY_NONE;
    }
    if (leaf(l)) {
      tr = expr(r);
      if (tr == TY_NONE) return false;
      a.mov_rcx_rax();
      tl = leaf_into(l, RAX);
      return tl != TY_NONE;
    }
    tl = expr(l);
    if (tl == TY_NONE) return false;
    a.push_rax();
    tr = expr(r);
    if (tr == TY_NONE) return false;
    a.mov_rcx_rax();
    a.pop_rax();
    return true;
  }

  // A call of the loop's own statements (docs/notes/ast.md, "The calls"). The function is a global, an upvalue, or a local that the loop
  // only calls. The arguments are numbers, computed into the stack area of the call and then given to the helper with the node, the
  // kind the code expects of the result (WANT: TY_INT, TY_FLT, or WANT_DISCARD), and the context. The helper returns the result's word in
  // RAX and a status in RDX: nonzero leaves the code through the site's stub, which writes the locals back (run() then raises the
  // callee's error, or finishes the statement with the call's value). The value is in RAX.
  int call_expr(Node* n, int want) {
    TierView v;
    tier_view(n, v);
    if (v.kind != TierView::K_CALL) return failt("internal: a call expected");
    if (v.multi_last) return failt("a call whose last argument is several values");
    if (args_depth > 0) return failt("a call among the arguments of a call");
    if (inner_loops > 0) return failt("a call in a loop inside the loop (the loop's statements are compiled only at its own level)");
    if (levels.empty()) return failt("a call in the condition of the loop");
    if (levels.back().calls > 0) return failt("two calls in one statement");
    int m = static_cast<int>(v.kids.size()) - 1;
    if (m > kMaxCallArgs) return failt("a call with more than 16 arguments");
    TierView fv;
    tier_view(v.kids[0], fv);
    if (fv.kind == TierView::K_LOCAL) {
      if (declared.count(fv.slot) || written.count(fv.slot) || reg_of.count(fv.slot))
        return failt("a local used as a function that the loop also computes with or assigns");
      callee_slots.insert(fv.slot);
    } else if (fv.kind != TierView::K_GLOBAL && fv.kind != TierView::K_UPVAL) {
      return failt("a call of something other than a global, an upvalue or a local");
    }
    ++levels.back().calls;
    if (ctx_word < 0) ctx_word = new_reg(false);
    if (m > 0) a.reserve(m);
    std::int64_t fmask = 0;
    ++args_depth;
    for (int k = 0; k < m; ++k) {
      int t = expr(v.kids[static_cast<std::size_t>(k) + 1]);
      if (t == TY_NONE) {
        --args_depth;
        return TY_NONE;
      }
      if (t == TY_FLT) fmask |= std::int64_t(1) << k;
      a.store_arg(k);
    }
    --args_depth;
    int code_want = want == TY_INT ? 1 : want == TY_FLT ? 2 : 0;
    a.load(RDI, ctx_word);
    a.mov_imm(RSI, static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(n)));
    a.mov_rr_pub(RDX, RSP);  // the arguments
    a.mov_imm(RCX, m);
    a.mov_imm(R8, code_want | (fmask << 8));
    call_c(reinterpret_cast<std::uintptr_t>(&jit_call_helper));
    if (m > 0) a.release(m);
    if (!unit_called.empty()) unit_called.back() = true;
    // The site: the locals as they are here, and the chain of the statements the interpreter runs after a call that stops the code.
    Code::Site site;
    site.kind = Code::Site::CALL;
    site.node = n;
    for (int lv = static_cast<int>(levels.size()) - 1; lv >= 0; --lv) {
      const Level& K = levels[static_cast<std::size_t>(lv)];
      std::size_t from = lv == static_cast<int>(levels.size()) - 1 ? K.idx : K.idx + 1;  // the statement itself, then the ones after it
      for (std::size_t j = from; j < K.kids->size(); ++j) site.chain.push_back((*K.kids)[j]);
    }
    for (const auto& kv : reg_of) {
      site.bail_slots.push_back(kv.first);
      site.bail_regs.push_back(kv.second);
    }
    sites.push_back(site);
    int stub = a.label();
    stubs.push_back(stub);
    int ok = a.label();
    a.test_rdx_rdx();
    a.jcc(CC_E, ok);
    if (a.pushes() > 0) a.add_rsp(a.pushes());
    a.mov_eax_imm(static_cast<std::uint32_t>(sites.size()));
    a.jmp(stub);
    a.bind(ok);
    return want == WANT_DISCARD ? TY_INT : want;
  }

  // The deopt sites. A zero divisor in RCX leaves the code: it drops the values pushed so far, and jumps to the stub with the number of
  // the site (the unit being generated) in EAX. The site is recorded here, so the interpreter can run that unit to raise the error.
  void zero_check() {
    int ok = a.label();
    if (units.empty()) {  // not reached: every operation is inside a unit (a statement, a condition or a for loop's expression)
      fail("internal: an operation outside a unit");
      return;
    }
    if (unit_called.back()) {  // the deopt would run the statement again, and the call with it
      fail("a division by a value that is not a constant after a call in the same statement");
      return;
    }
    Code::Site s = units.back();
    for (const auto& kv : reg_of) {  // the locals as they are here (the live-ins seen so far; the rest are added at the end)
      s.bail_slots.push_back(kv.first);
      s.bail_regs.push_back(kv.second);
    }
    sites.push_back(s);
    int stub = a.label();
    stubs.push_back(stub);
    a.test_rcx_rcx();
    a.jcc(CC_NE, ok);
    if (a.pushes() > 0) a.add_rsp(a.pushes());
    a.mov_eax_imm(static_cast<std::uint32_t>(sites.size()));
    a.jmp(stub);
    a.bind(ok);
  }

  // RAX = RAX // RCX (MOD false) or RAX % RCX (MOD true), for integers, as the interpreter's helpers (nfcr_idiv, nfcr_imod) compute
  // them. The divisor is checked first (zero_check). The x86 idiv traps on INT_MIN / -1, so a divisor of -1 is special-cased: the
  // quotient is -a, the remainder 0 (what the interpreter's helpers give, with the wraparound). Otherwise idiv gives the quotient
  // rounded towards zero and the remainder with the sign of the dividend, and the floor values are one less (quotient) or the divisor
  // added (remainder) when the remainder is not zero and its sign differs from the divisor's.
  void floordiv(bool mod) {
    zero_check();
    int norm = a.label(), done = a.label();
    a.cmp_rcx_m1();
    a.jcc(CC_NE, norm);
    if (mod) a.xor_eax_eax();
    else a.neg_rax();
    a.jmp(done);
    a.bind(norm);
    a.cqo();
    a.idiv_rcx();
    if (!mod) {  // RAX = quotient, RDX = remainder
      a.test_rdx_rdx();
      a.jcc(CC_E, done);
      a.xor_rdx_rcx();  // the sign of remainder ^ divisor
      a.jcc(CC_NS, done);
      a.sub_rax_1();
    } else {  // RDX = remainder
      a.mov_rax_rdx();
      a.test_rax_rax();
      a.jcc(CC_E, done);
      a.mov_rdx_rax();
      a.xor_rdx_rcx();
      a.jcc(CC_NS, done);
      a.add_rax_rcx();
    }
    a.bind(done);
  }

  // Jumps to TARGET when the condition N has the truth value JUMP_IF (Lua's: nil and false are false, everything else true).
  bool branch(Node* n, bool jump_if, int target) {
    push_unit(n, false);
    bool r = branch_(n, jump_if, target);
    pop_unit();
    return r;
  }

  // A numeric expression that is a unit of its own (the start and the limit of a for loop): its value is in RAX, its type is returned.
  int num_unit(Node* n) {
    push_unit(n, false);
    int t = expr(n);
    pop_unit();
    return t;
  }

  bool branch_(Node* n, bool jump_if, int target) {
    if (!n) return fail("a condition that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_CMP:
        if (v.op < 0 || v.op > 5) return fail("a comparison outside the subset");
        return compare(v.kids, v.op, jump_if, target);
      case TierView::K_EQ:
        return compare(v.kids, v.flag ? 1 : 0, jump_if, target);  // CMP_NE, CMP_EQ
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
    if (expr(n) == TY_NONE) return false;
    if (jump_if) a.jmp(target);
    return true;
  }

  // A comparison of two operands, OP being the CMP_* index (CMP_EQ, CMP_NE, CMP_LT, CMP_LE, CMP_GT, CMP_GE). Two integers compare as
  // the integers do; two floats compare with ucomisd, where an unordered pair (a nan) makes every comparison false except ~=.
  // The comparison of an integer with a float (the operands in RAX and RCX, the left one of type TL). The interpreter compares those
  // exactly, not by converting the integer (nfcr_lt_if and its kin, and raw_equal for ==), so the code calls those functions: the
  // integer in RDI, the float in XMM0, and the result (0 or 1) in RAX. `>` and `>=` are the `<` and `<=` of the operands swapped, as
  // the interpreter has them. A `~=` is the negated `==`.
  bool mixed_compare(int tl, int op, bool jump_if, int target) {
    bool lhs_int = tl == TY_INT;
    a.mov_rr_pub(RDI, lhs_int ? RAX : RCX);
    a.movq_x_r(0, lhs_int ? RCX : RAX);
    bool neg = false;
    std::uintptr_t fn = 0;
    switch (op) {
      case CMP_EQ: fn = reinterpret_cast<std::uintptr_t>(&jit_eq); break;
      case CMP_NE: fn = reinterpret_cast<std::uintptr_t>(&jit_eq); neg = true; break;
      case CMP_LT: case CMP_GT: {  // the left operand of the `<` is the one that is first in the comparison
        bool lo_int = op == CMP_LT ? lhs_int : !lhs_int;
        fn = reinterpret_cast<std::uintptr_t>(lo_int ? &jit_lt_if : &jit_lt_fi);
        break;
      }
      default: {  // CMP_LE, CMP_GE
        bool lo_int = op == CMP_LE ? lhs_int : !lhs_int;
        fn = reinterpret_cast<std::uintptr_t>(lo_int ? &jit_le_if : &jit_le_fi);
        break;
      }
    }
    call_c(fn);
    a.test_rax_rax();
    bool when_nonzero = jump_if != neg;  // the jump is taken when the result is nonzero (else when it is zero)
    a.jcc(when_nonzero ? CC_NE : CC_E, target);
    return true;
  }

  bool compare(const std::vector<Node*>& kids, int op, bool jump_if, int target) {
    if (kids.size() != 2) return fail("a comparison without two operands");
    int tl = TY_NONE, tr = TY_NONE;
    if (!binary(kids[0], kids[1], tl, tr)) return false;
    if (tl != tr) return mixed_compare(tl, op, jump_if, target);
    if (tl == TY_INT) {
      static const int cc[] = {CC_E, CC_NE, CC_L, CC_LE, CC_G, CC_GE};
      a.cmp_rax_rcx();
      a.jcc(jump_if ? cc[op] : (cc[op] ^ 1), target);
      return true;
    }
    to_xmm(TY_FLT, TY_FLT);
    switch (op) {
      // ucomisd sets CF for "below" (and for unordered), ZF for "equal" and PF for unordered. a < b is b above a (ucomisd xmm1, xmm0):
      // above is false for an unordered pair, and so is its negation's complement, below-or-equal, taken on the false edge.
      case 2:  // CMP_LT
        a.ucomisd(1, 0);
        a.jcc(jump_if ? CC_A : CC_BE, target);
        return true;
      case 3:  // CMP_LE
        a.ucomisd(1, 0);
        a.jcc(jump_if ? CC_AE : CC_B, target);
        return true;
      case 4:  // CMP_GT
        a.ucomisd(0, 1);
        a.jcc(jump_if ? CC_A : CC_BE, target);
        return true;
      case 5:  // CMP_GE
        a.ucomisd(0, 1);
        a.jcc(jump_if ? CC_AE : CC_B, target);
        return true;
      case 0:  // CMP_EQ: equal is ZF with no PF (an unordered pair sets both)
        a.ucomisd(0, 1);
        if (jump_if) {
          int skip = a.label();
          a.jcc(CC_P, skip);
          a.jcc(CC_E, target);
          a.bind(skip);
        } else {
          a.jcc(CC_P, target);
          a.jcc(CC_NE, target);
        }
        return true;
      default:  // CMP_NE: the negation of equal
        a.ucomisd(0, 1);
        if (jump_if) {
          a.jcc(CC_P, target);
          a.jcc(CC_NE, target);
        } else {
          int skip = a.label();
          a.jcc(CC_P, skip);
          a.jcc(CC_E, target);
          a.bind(skip);
        }
        return true;
    }
  }

  bool stmt(Node* n) {
    if (!n) return fail("a statement that is missing");
    TierView v;
    tier_view(n, v);
    switch (v.kind) {
      case TierView::K_BLOCK:
        levels.push_back(Level{&v.kids, 0, 0});
        for (std::size_t i = 0; i < v.kids.size(); ++i) {
          levels.back().idx = i;
          levels.back().calls = 0;
          if (!stmt(v.kids[i])) {
            levels.pop_back();
            return false;
          }
        }
        levels.pop_back();
        return true;
      case TierView::K_DECL:
      case TierView::K_ASSIGN: {  // a unit of its own: its stores come after all its operands (a deopt runs the statement again)
        push_unit(n, true);
        bool r = v.kind == TierView::K_DECL ? decl(v) : assign(v);
        pop_unit();
        return r;
      }
      case TierView::K_CALL: {  // a call whose result is not used: no kind to check
        push_unit(n, true);
        int t = call_expr(n, WANT_DISCARD);
        pop_unit();
        return t != TY_NONE;
      }
      case TierView::K_IF:
        return conditional(v);
      case TierView::K_WHILE:
      case TierView::K_REPEAT:
      case TierView::K_FOR: {
        ++inner_loops;
        bool r = v.kind == TierView::K_WHILE ? while_loop(v) : v.kind == TierView::K_REPEAT ? repeat_loop(v) : for_loop(v);
        --inner_loops;
        return r;
      }
      case TierView::K_BREAK:
        if (breaks.empty()) return fail("a break outside a loop");
        a.jmp(breaks.back());
        return true;
      case TierView::K_RETURN:
        return fail("a return inside the loop");
      default:
        return fail("a statement outside the subset");
    }
  }

  bool decl(const TierView& v) {
    if (v.captured) return fail("a local captured by a closure");
    if (v.kids.size() != v.slots.size()) return fail("a local declared without one value per name");  // a last call is cut to one value
    if (v.slots.size() == 1) {  // one local: its value goes straight to its register (a call's value is an integer, or the interpreter goes on)
      int t = expr(v.kids[0], TY_INT);
      if (t == TY_NONE) return false;
      int r = declare_reg(v.slots[0], t);
      if (r < 0) return false;
      a.store(r, RAX);
      seen.insert(v.slots[0]);
      return true;
    }
    std::vector<int> ts;
    for (Node* k : v.kids) {
      int t = expr(k, TY_INT);
      if (t == TY_NONE) return false;
      ts.push_back(t);
      a.push_rax();
    }
    for (std::size_t i = v.slots.size(); i-- > 0;) {
      a.pop_rax();
      int r = declare_reg(v.slots[i], ts[i]);
      if (r < 0) return false;
      a.store(r, RAX);
    }
    for (int s : v.slots) seen.insert(s);
    return true;
  }

  // Stores RAX (of type T) into the local of word R: its type must be the local's.
  bool store_typed(int r, int t) {
    if ((t == TY_FLT) != is_flt(r)) return fail("an assignment that changes the type of a local (an integer and a float)");
    a.store(r, RAX);
    return true;
  }

  bool assign(const TierView& v) {
    if (v.captured) return fail("an assignment to a captured local, an upvalue, a global or a field");
    for (int t : v.tkinds)
      if (t != TierView::T_LOCAL) return fail("an assignment to a captured local, an upvalue, a global or a field");
    if (v.kids.size() != v.slots.size()) return fail("an assignment of other than one value per target");  // a last call is cut to one value
    std::vector<int> rs;  // the word of each target (a call's value has the kind of its target)
    for (int slot : v.slots) {
      int r = slot_reg(slot, true);
      if (r < 0) return false;
      rs.push_back(r);
    }
    if (v.slots.size() == 1) {  // one target: its value goes straight to its word
      int t = expr(v.kids[0], is_flt(rs[0]) ? TY_FLT : TY_INT);
      if (t == TY_NONE) return false;
      return store_typed(rs[0], t);
    }
    std::vector<int> ts;
    for (std::size_t i = 0; i < v.kids.size(); ++i) {
      int t = expr(v.kids[i], is_flt(rs[i]) ? TY_FLT : TY_INT);
      if (t == TY_NONE) return false;
      ts.push_back(t);
      a.push_rax();
    }
    for (std::size_t i = v.slots.size(); i-- > 0;) {
      a.pop_rax();
      if (!store_typed(rs[i], ts[i])) return false;
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

  // A numeric `for` inside the loop. The step is a numeric constant, not zero (the interpreter's NumForNode decides the kind of the
  // loop from its start and step: an integer loop when both are integers, a float loop otherwise, see float_for).
  bool for_loop(const TierView& v) {
    if (v.captured) return fail("a loop variable captured by a closure");
    bool step_flt = false;
    std::int64_t step = 1;
    double dstep = 1.0;
    if (v.kids.size() == 3 && v.kids[2]) {
      TierView sv;
      tier_view(v.kids[2], sv);
      if (sv.kind != TierView::K_CONST || (sv.k.t != T_INT && sv.k.t != T_FLT)) return fail("a for loop whose step is not a numeric constant");
      if (sv.k.t == T_INT) {
        step = sv.k.i;
        dstep = static_cast<double>(step);
      } else {
        step_flt = true;
        dstep = sv.k.d;
      }
      if (step_flt ? dstep == 0 : step == 0) return fail("a for loop with a step of zero (an error the interpreter reports)");
    }
    int ty = num_unit(v.kids[0]);  // the start, in RAX
    if (ty == TY_NONE) return false;
    if (ty == TY_INT && !step_flt) return int_for(v, step);
    return float_for(v, ty, dstep);
  }

  // An integer loop (the start in RAX). Its limit is an integer, or a float that nfcr_forlimit clips (a loop it does not run is skipped).
  bool int_for(const TierView& v, std::int64_t step) {
    int done = a.label(), top = a.label();
    int hi = new_reg(false);
    a.store(hi, RAX);
    int tl = num_unit(v.kids[1]);
    if (tl == TY_NONE) return false;
    int hl = new_reg(false), hc = new_reg(false);
    if (tl == TY_FLT) {  // RAX is the float limit: the call clips it (JitLimit: RAX the limit, RDX whether the loop runs)
      a.movq_x_r(0, RAX);
      a.mov_imm(RDI, step);
      call_c(reinterpret_cast<std::uintptr_t>(&jit_forlimit));
      a.test_rdx_rdx();
      a.jcc(CC_E, done);
    }
    a.store(hl, RAX);
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
    int var = declare_reg(v.slots[0], TY_INT);
    if (var < 0) return false;
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

  // A float loop (the start in RAX, of type TY; the step is DSTEP, a constant). Its values are doubles: the start, the limit and the
  // step are converted to them, as the interpreter does (num_d), and the variable is a float.
  bool float_for(const TierView& v, int ty, double dstep) {
    int hi = new_reg(true), hl = new_reg(true), hs = new_reg(true);
    to_flt_rax(ty);
    a.store(hi, RAX);
    int tl = num_unit(v.kids[1]);
    if (tl == TY_NONE) return false;
    to_flt_rax(tl);
    a.store(hl, RAX);
    a.mov_imm(RAX, bits_of(dstep));
    a.store(hs, RAX);
    int var = declare_reg(v.slots[0], TY_FLT);
    if (var < 0) return false;
    seen.insert(v.slots[0]);
    int done = a.label(), top = a.label();
    a.enter_loop();
    first_skip(hi, hl, hs, done);
    a.bind(top);
    a.load(RAX, hi);
    a.store(var, RAX);
    breaks.push_back(done);
    if (!stmt(v.blocks[0])) return false;
    breaks.pop_back();
    fincrement(hi, hs);
    next_continue(hi, hl, hs, top);
    a.bind(done);
    a.leave_loop();
    return true;
  }

  // RAX = the float value of RAX when its type is an integer (converted as the interpreter's num_d does).
  void to_flt_rax(int ty) {
    if (ty != TY_INT) return;
    a.cvtsi2sd(0, RAX);
    a.movq_r_x(RAX, 0);
  }
  // xmmX = the float word W (through RAX).
  void fload(int x, int w) {
    a.load(RAX, w);
    a.movq_x_r(x, RAX);
  }
  // idx += step (the word HI).
  void fincrement(int hi, int hs) {
    fload(0, hi);
    fload(1, hs);
    a.sd_op(0x58, 0, 1);  // addsd
    a.movq_r_x(RAX, 0);
    a.store(hi, RAX);
  }
  // The first iteration of a float loop does not run when (0 < step ? limit < idx : idx < limit) (the interpreter's test, which a nan
  // does not satisfy: the body runs once for it). Jumps to DONE then.
  void first_skip(int hi, int hl, int hs, int done) {
    int neg = a.label(), run = a.label();
    fload(0, hs);
    a.zero_x(2);
    a.ucomisd(0, 2);
    a.jcc(CC_BE, neg);  // not 0 < step (a nan step too)
    fload(0, hi);
    fload(1, hl);
    a.ucomisd(0, 1);
    a.jcc(CC_A, done);  // idx > limit
    a.jmp(run);
    a.bind(neg);
    fload(0, hl);
    fload(1, hi);
    a.ucomisd(0, 1);
    a.jcc(CC_A, done);  // limit > idx
    a.bind(run);
  }
  // After an iteration the loop goes on at TOP while (0 < step ? idx <= limit : limit <= idx) holds, and falls through otherwise (the
  // interpreter's condition; a nan makes it false).
  void next_continue(int hi, int hl, int hs, int top) {
    int neg = a.label(), end = a.label();
    fload(0, hs);
    a.zero_x(2);
    a.ucomisd(0, 2);
    a.jcc(CC_BE, neg);
    fload(0, hl);
    fload(1, hi);
    a.ucomisd(0, 1);
    a.jcc(CC_AE, top);  // limit >= idx
    a.jmp(end);
    a.bind(neg);
    fload(0, hi);
    fload(1, hl);
    a.ucomisd(0, 1);
    a.jcc(CC_AE, top);  // idx >= limit
    a.bind(end);
  }
};

// The loop itself: a `while`, a `repeat`, or the numeric `for` the takeover starts in (its state comes in the registers).
bool top_level(Gen& g, Node* loop, int kind, Code& code) {
  TierView v;
  tier_view(loop, v);
  g.collect(loop);
  g.a.prologue();
  if (kind == TierLoopState::REPEAT && v.kind == TierView::K_REPEAT) code.until = v.cond;
  if (kind == TierLoopState::FOR_INT) {
    if (v.kind != TierView::K_FOR) return g.fail("a loop that is not a numeric for");
    if (v.captured) return g.fail("a loop variable captured by a closure");
    int hi = g.new_reg(false), hc = g.new_reg(false), hs = g.new_reg(false);
    code.state_regs[0] = hi;
    code.state_regs[1] = hc;
    code.state_regs[2] = hs;
    int var = g.declare_reg(v.slots[0], TY_INT);
    if (var < 0) return false;
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
  } else if (kind == TierLoopState::FOR_FLT) {
    if (v.kind != TierView::K_FOR) return g.fail("a loop that is not a numeric for");
    if (v.captured) return g.fail("a loop variable captured by a closure");
    // The state of a float loop at the top of an iteration: the next value, the limit and the step, all doubles. The entry (from the
    // start, as the interpreter's test passed, or after an iteration) takes the plain condition: the takeover never has a nan start or
    // limit, and for numbers that are not nan the plain condition is the interpreter's first test.
    int hi = g.new_reg(true), hl = g.new_reg(true), hs = g.new_reg(true);
    code.state_regs[0] = hi;
    code.state_regs[1] = hl;
    code.state_regs[2] = hs;
    int var = g.declare_reg(v.slots[0], TY_FLT);
    if (var < 0) return false;
    g.seen.insert(v.slots[0]);
    int done = g.a.label(), top = g.a.label(), check = g.a.label();
    g.a.enter_loop();
    g.a.jmp(check);
    g.a.bind(top);
    g.a.load(RAX, hi);
    g.a.store(var, RAX);
    g.breaks.push_back(done);
    if (!g.stmt(v.blocks[0])) return false;
    g.breaks.pop_back();
    g.fincrement(hi, hs);
    g.a.bind(check);
    g.next_continue(hi, hl, hs, top);
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
  // The deopt stubs (a zero divisor jumps to the stub of its site, with the site in EAX and its pushes dropped): the locals of the site
  // go back to REGS (an allocated one from its register; the others are in memory already), then the registers are restored and the
  // code returns the site. Nothing else is written: the statement the site names is run by the interpreter from this state.
  // The live-ins are all in the stubs: one first used after a site in the text can be assigned before the site is reached again.
  for (std::size_t k = 0; k < g.sites.size(); ++k) {
    g.a.bind(g.stubs[k]);
    for (int r : g.sites[k].bail_regs) g.a.spill(r);
    for (int r : g.in_regs)
      if (std::find(g.sites[k].bail_regs.begin(), g.sites[k].bail_regs.end(), r) == g.sites[k].bail_regs.end()) g.a.spill(r);
    for (int r : code.state_regs)  // the state of the loop (a call's stub hands it to the interpreter, see finish_call)
      if (r >= 0) g.a.spill(r);
    g.a.restore_ret();
  }
  return g.ok;
}

}  // namespace
#endif  // NFCAST_JIT_X64

std::unique_ptr<Code> compile(Node* loop, int kind, const Frame& f, std::string& why) {
#if NFCAST_JIT_X64
  // Register allocation: the first pass generates the loop with every word in memory and counts the references to each word (weighted
  // by loop depth, so the control variables, referenced on every iteration, rank first). The four most referenced words get R12-R15
  // (callee-saved) and the second pass generates the code with them. The allocation does not change what is in the subset, so the
  // second pass accepts the loop when the first did.
  const int kFirstAllocReg = 12, kAllocRegs = 4;  // R12..R15
  Gen g1;
  g1.fr = &f;
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
  g.fr = &f;
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
  code->ctx_reg = g.ctx_word;
  code->reg_float = g.flt;
  code->sites = g.sites;
  for (Code::Site& s : code->sites) {  // the live-ins are written back at every site, whether they were seen before it or not
    for (std::size_t k = 0; k < g.in_slots.size(); ++k) {
      if (std::find(s.bail_slots.begin(), s.bail_slots.end(), g.in_slots[k]) != s.bail_slots.end()) continue;
      s.bail_slots.push_back(g.in_slots[k]);
      s.bail_regs.push_back(g.in_regs[k]);
    }
  }
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
  (void)f;
  why = "the JIT is not available on this host (it is written for x86-64 Linux)";
  return nullptr;
#endif
}

}  // namespace jit
}  // namespace nfcast
