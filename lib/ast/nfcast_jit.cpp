// nfcast JIT: x86-64 machine code for the loops of the AST interpreter (docs/notes/ast.md, "JIT"). The loop is read through the
// tier's view of its nodes (tier_view), the same one the C tier lowers from, and only the subset listed in the notes is encoded:
// integers and floats (the float operators + - * / // % ^ and unary minus, the comparisons of two floats and of an integer with a float
// as the interpreter does them, and the mixed arithmetic of an integer and a float), integer `//` and `%` (floor division and modulo,
// as the interpreter's), the bitwise operators & | ~ (binary xor), << and >> and unary ~ on integers, comparisons of two integers,
// and/or/not in conditions, if, while, repeat, numeric for loops with a constant step (integer or float, not zero; an integer loop
// takes a float limit as the interpreter clips it, and a loop with a float start or step is a float loop), break, and locals. Integer arithmetic wraps as the interpreter's does, and the bitwise operators never fail. The one
// operation that can fail is integer `//` or `%` by zero, and the table operations of the array part (table elements, see "Table
// elements" in the notes): the code then stops, writes its locals back, and the interpreter runs the unit the operation is in (the
// deopt, see run()); a zero divisor raises its error there, a table operation goes on. Everything else outside the subset makes
// compile() refuse the loop.
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
//
// Tables. A live-in table (a local the loop indexes) is a register with its Table* word. A table element is read or written in the array
// part, at offsets of the Table and its Values taken from the interpreter's own layout (table_offsets, value_layout_ok); every other
// access is a deopt, and the interpreter goes on with the unit it is in (see run()). The code keeps no table field in a register: it reads
// arr and asize at each access.
#include "nfcast_jit.hpp"

#include <algorithm>
#include <cstddef>
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
    std::size_t r = static_cast<std::size_t>(c.in_regs[k]);
    auto want = c.reg_tab[r] ? T_TAB : c.reg_float[r] ? T_FLT : T_INT;
    if (f.base[c.in_slots[k]].t != want) return false;
  }
  return true;
}

void run(Frame& f, const Code& c, const TierLoopState& st, std::uint64_t& bailouts) {
  std::int64_t small[64] = {0};
  std::vector<std::int64_t> big;
  std::int64_t* R = small;
  if (c.nregs > 64) {
    big.assign(static_cast<std::size_t>(c.nregs), 0);
    R = big.data();
  }
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
  // The registers are the loop's state between the deopts: the interpreter's unit writes table elements and nothing else of the loop,
  // so REGS is still right after it, and the code goes on from the continuation with the words it had (the registers are reloaded from
  // REGS at every entry).
  int entry = 0;
  for (;;) {
    int site = c.fn(R, entry);
    if (site == 0) break;
    const Code::Site& s = c.sites[static_cast<std::size_t>(site - 1)];
    ++bailouts;
    for (std::size_t k = 0; k < s.bail_slots.size(); ++k) {  // the locals of the site go back to the frame, as they are at the operation
      std::size_t r = static_cast<std::size_t>(s.bail_regs[k]);
      f.base[s.bail_slots[k]] = word_value(c.reg_float[r] != 0, R[s.bail_regs[k]]);
    }
    if (s.kind == Code::Site::STMT) {
      s.node->exec(f);
      entry = s.entry;
    } else if (s.kind == Code::Site::COND) {
      entry = s.node->eval(f).truthy() ? s.entry : s.entry_false;
    } else {
      // The unit raises the error of its operation (the same message, at the same line: the operation sets the line before it raises).
      if (s.stmt) s.node->exec(f);
      else s.node->eval(f);
      f.S->rt_error("internal: the machine code stopped at an operation that did not raise its error");
    }
  }
  for (std::size_t k = 0; k < c.out_slots.size(); ++k) {
    std::size_t r = static_cast<std::size_t>(c.out_regs[k]);
    f.base[c.out_slots[k]] = word_value(c.reg_float[r] != 0, R[c.out_regs[k]]);
  }
}

#if NFCAST_JIT_X64
namespace {

// ---- the encoder --------------------------------------------------------------------------------------------------------------
enum { RAX = 0, RCX = 1, RDX = 2, RDI = 7, R8 = 8, R9 = 9, R10 = 10 };
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
  void mov_imm(int reg, std::int64_t v) {
    std::uint8_t rex = static_cast<std::uint8_t>(0x48 | (reg >> 3));  // REX.W, and REX.B for R8-R15
    if (v >= INT32_MIN && v <= INT32_MAX) {
      b.push_back(rex);
      b.push_back(0xC7);
      b.push_back(static_cast<std::uint8_t>(0xC0 | (reg & 7)));
      u32(static_cast<std::uint32_t>(v));
    } else {
      b.push_back(rex);
      b.push_back(static_cast<std::uint8_t>(0xB8 | (reg & 7)));
      u64(static_cast<std::uint64_t>(v));
    }
  }
  // ---- table elements (the Table of nfcast.hpp): their memory is read and written at the interpreter's offsets. The bases are RDX and
  // RCX, and R8-R10 hold the values in between; no call is made while they hold anything.
  void load32_mem(int reg, int base, std::int32_t disp) { mem_ext(false, 0x8B, reg, base, disp); }   // mov r32, [base+disp]
  void load64_mem(int reg, int base, std::int32_t disp) { mem_ext(true, 0x8B, reg, base, disp); }    // mov r64, [base+disp]
  void store64_mem(int base, std::int32_t disp, int reg) { mem_ext(true, 0x89, reg, base, disp); }   // mov [base+disp], r64
  void store8_mem(int base, std::int32_t disp, int reg) { mem_ext(false, 0x88, reg, base, disp); }   // mov byte [base+disp], r8
  void store8_imm_mem(int base, std::int32_t disp, std::uint8_t v) {  // mov byte [base+disp], imm8
    mem_ext(false, 0xC6, 0, base, disp);
    b.push_back(v);
  }
  void cmp64_mem_imm0(int base, std::int32_t disp) {  // cmp qword [base+disp], 0
    mem_ext(true, 0x83, 7, base, disp);
    b.push_back(0);
  }
  void movzx_eax_mem8(int base) {  // movzx eax, byte [base] (base RCX or RDX)
    b.push_back(0x0F);
    b.push_back(0xB6);
    b.push_back(modrm(0, RAX, base));
  }
  void cmp_eax_imm8(std::uint8_t v) {
    bytes({0x83, 0xF8, v});
  }
  void test_eax_eax() { bytes({0x85, 0xC0}); }
  void cmp_rr(int x, int y) {  // flags of X - Y (64-bit)
    b.push_back(static_cast<std::uint8_t>(0x48 | ((y >> 3) << 2) | (x >> 3)));
    b.push_back(0x39);
    b.push_back(modrm(3, y, x));
  }
  void add_rr(int dst, int src) {  // dst += src (64-bit)
    b.push_back(static_cast<std::uint8_t>(0x48 | ((src >> 3) << 2) | (dst >> 3)));
    b.push_back(0x01);
    b.push_back(modrm(3, src, dst));
  }
  void sub_r_imm8(int r, std::uint8_t v) {  // r -= imm8 (64-bit)
    b.push_back(static_cast<std::uint8_t>(0x48 | (r >> 3)));
    b.push_back(0x83);
    b.push_back(modrm(3, 5, r));
    b.push_back(v);
  }
  void shl_r_imm8(int r, std::uint8_t v) {  // r <<= imm8 (64-bit)
    b.push_back(static_cast<std::uint8_t>(0x48 | (r >> 3)));
    b.push_back(0xC1);
    b.push_back(modrm(3, 4, r));
    b.push_back(v);
  }
  void cmp_esi_imm32(std::uint32_t v) {  // the entry number the code is entered with (the second argument, ESI)
    bytes({0x81, 0xFE});
    u32(v);
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
  // OPC with REG and [BASE + DISP32] (BASE is not RSP or R12, nor RBP or R13 for a disp-less form: every operand here has one). W: REX.W.
  void mem_ext(bool w, std::uint8_t opc, int reg, int base, std::int32_t disp) {
    int rex = 0x40 | (w ? 8 : 0) | ((reg >> 3) << 2) | (base >> 3);
    if (rex != 0x40) b.push_back(static_cast<std::uint8_t>(rex));
    b.push_back(opc);
    b.push_back(static_cast<std::uint8_t>(0x80 | ((reg & 7) << 3) | (base & 7)));
    u32(static_cast<std::uint32_t>(disp));
  }
  void mem_op(std::uint8_t opc, int reg, int k) {
    b.push_back(static_cast<std::uint8_t>(0x48 | ((reg >> 3) << 2)));
    b.push_back(opc);
    b.push_back(static_cast<std::uint8_t>(0x80 | ((reg & 7) << 3) | 0x03));
    u32(static_cast<std::uint32_t>(8 * k));
  }
};

// The fields of a Table the code reads and writes (nfcast.hpp): the array part, its size, the metatable, and the cache of absent metamethods.
// (Table derives from GCObject and both hold fields, so it is not standard layout: its offsets are taken from the address of each field
// in a table's memory, which is only named here, never read.)
struct TableOffsets {
  std::int32_t arr, asize, meta, absent;
};
static TableOffsets table_offsets() {
  alignas(Table) static unsigned char mem[sizeof(Table)];
  Table* t = reinterpret_cast<Table*>(mem);
  const unsigned char* base = mem;
  auto at = [base](const void* p) { return static_cast<std::int32_t>(static_cast<const unsigned char*>(p) - base); };
  return TableOffsets{at(&t->arr), at(&t->asize), at(&t->meta), at(&t->absent)};
}
static const TableOffsets kTableOff = table_offsets();

// The layout of a Value the code reads and writes: 16 bytes, the tag (one byte) at 0 and the payload at 8. Checked, so that the code is
// refused rather than wrong on a build that lays a Value out otherwise.
static bool value_layout_ok() {
  alignas(Value) static unsigned char mem[sizeof(Value)];
  Value* v = reinterpret_cast<Value*>(mem);
  const unsigned char* base = mem;
  const unsigned char* tag = reinterpret_cast<const unsigned char*>(&v->t);
  const unsigned char* pay = reinterpret_cast<const unsigned char*>(&v->i);
  return sizeof(Value) == 16 && tag == base && pay == base + 8 && sizeof(Tag) == 1;
}

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
  std::vector<char> tab;        // per register: 1 when it holds a live-in table (see Code::reg_tab)
  // The units being generated, innermost last: a statement, a condition or an expression that the interpreter runs when its operation
  // leaves the code (see Code::Site). A statement unit continues at CONT, the label after it; a condition unit at ENTRY_T or ENTRY_F
  // (the entries of its two truth values, made when a site needs them: their stubs jump to TARGET or FALL, the branch's jump and the
  // code after it).
  enum { U_EXPR = 0, U_STMT = 1, U_COND = 2 };
  struct Unit {
    Node* node = nullptr;
    int kind = U_EXPR;
    int cont = -1;
    int entry = 0;                // U_STMT: the entry number of CONT, 0 until a site needs it
    int target = -1, fall = -1;   // U_COND: the branch's jump target and the label after its code
    int jump_if = 0;              // U_COND: the truth value that jumps to TARGET
    int entry_t = 0, entry_f = 0; // U_COND: the entry numbers, 0 until a site needs them
  };
  std::vector<Unit> units;
  std::vector<Code::Site> sites;  // SITES[k - 1] is the site numbered k (the value the code leaves with in EAX)
  std::vector<int> stubs;         // STUBS[k - 1] the label of its stub, bound at the end of top_level
  std::vector<int> entries;       // ENTRIES[e - 1] the label the code continues at when it is entered with e (see Code::Site)
  struct CondStub {
    int label, target;
  };
  std::vector<CondStub> cond_stubs;  // the stubs of the entries of the condition units: a jump to TARGET
  bool tab_ok = false;          // a table element may be read here: in a condition, or in a store to a table (see index_value)

  static Unit make_unit(Node* n, int kind) {
    Unit u;
    u.node = n;
    u.kind = kind;
    return u;
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
    tab.push_back(0);
    return nregs++;
  }
  // A register of a live-in of the kind of its value in the frame: 0 an integer, 1 a float, 2 a table.
  int new_reg_of_kind(int kind) {
    int r = new_reg(kind == 1);
    tab[static_cast<std::size_t>(r)] = kind == 2 ? 1 : 0;
    return r;
  }
  int entry_kind(int slot) const {
    if (!fr) return 0;
    Tag t = fr->base[slot].t;
    return t == T_TAB ? 2 : t == T_FLT ? 1 : 0;
  }
  bool is_tab(int r) const { return tab[static_cast<std::size_t>(r)] != 0; }

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
      int r = new_reg_of_kind(entry_kind(slot));
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
  int expr(Node* n) {
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
        if (is_tab(r)) return failt("a table used as a number");
        a.load(RAX, r);
        return is_flt(r) ? TY_FLT : TY_INT;
      }
      case TierView::K_INDEX:
        return index_value(n, false);
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
        return failt("a call");
      case TierView::K_UPVAL:
      case TierView::K_GLOBAL:
        return failt("an upvalue or a global");
      default:
        return failt("an expression outside the subset");
    }
  }

  // ---- table elements (Table, nfcast.hpp) ----------------------------------------------------------------------------------------------
  // A table element is read or written in the array part only: a key in 1..asize, in a table with no metatable (a store). Every other
  // case is a deopt (a site of the unit, see new_site): the interpreter runs the unit, which does what it does (the hash part, a grow, a
  // metamethod, an error), and the code goes on after it. The element's kind is not a static type: a read is taken as the integer (or
  // float) the operation needs, and an element of another kind is a deopt. So a value read from a table is never assigned to a local
  // (the interpreter's own result could be of another kind than the local, which the code cannot resume past); it is read in a condition
  // (whose truth the interpreter gives back) or stored into a table (whose element takes the tag and payload of the value).

  // The register of the table that the expression N names: a live-in local of the loop (the guard checks it is a table at entry).
  int table_of(Node* n) {
    TierView v;
    tier_view(n, v);
    if (v.kind != TierView::K_LOCAL || v.flag) return fail_r("an indexed value that is not a table local (a field, a call, an upvalue)");
    if (declared.count(v.slot)) return fail_r("a table declared in the loop");
    int r = slot_reg(v.slot, false);
    if (r < 0) return -1;
    if (!is_tab(r)) return fail_r("an indexed value that is not a table");
    return r;
  }
  int fail_r(const std::string& m) {
    fail(m);
    return -1;
  }
  // A deopt at a table operation (see new_site): true when the site is made.
  bool tdeopt(int cc) {
    int k = new_site(true);
    if (!k) return false;
    deopt_jump(cc, k);
    return true;
  }
  // RCX = the address of the element at the key in RAX (an integer) of the table in the register TR, when the key is in 1..asize (RDX holds
  // the table, R10 the key less one). Any other key is a deopt. Reads the table's fields each time: the array can move when it grows.
  bool elem_addr(int tr) {
    a.mov_rr_pub(R10, RAX);
    a.sub_r_imm8(R10, 1);
    a.load(RDX, tr);
    a.load32_mem(RCX, RDX, kTableOff.asize);
    a.cmp_rr(R10, RCX);
    if (!tdeopt(CC_AE)) return false;  // unsigned: key-1 >= asize (the key is outside the array part)
    a.load64_mem(RCX, RDX, kTableOff.arr);
    a.shl_r_imm8(R10, 4);
    a.add_rr(RCX, R10);
    return true;
  }
  // A table element read as a number, into RAX: an integer, or a float when FLT. Any other element is a deopt.
  int index_value(Node* n, bool flt) {
    TierView v;
    tier_view(n, v);
    if (!tab_ok) return failt("a table element read into a local, or in an expression outside a condition or a table store");
    int tr = table_of(v.kids[0]);
    if (tr < 0) return TY_NONE;
    if (expr(v.kids[1]) != TY_INT) return failt("a table read at a key that is not an integer expression");
    if (!elem_addr(tr)) return TY_NONE;
    a.movzx_eax_mem8(RCX);
    a.cmp_eax_imm8(static_cast<std::uint8_t>(flt ? T_FLT : T_INT));
    if (!tdeopt(CC_NE)) return TY_NONE;
    a.load64_mem(RAX, RCX, 8);
    return flt ? TY_FLT : TY_INT;
  }
  // The value of N as a number of the kind a table element is read as: a table read takes the float kind when its other operand is a float.
  int expr_hint(Node* n, bool flt) {
    TierView v;
    tier_view(n, v);
    if (v.kind == TierView::K_INDEX) return index_value(n, flt);
    return expr(n);
  }
  // A constant float, or a local of the loop or a live-in that holds a float (the kind a table read beside it is taken as).
  bool is_float_leaf(Node* n) {
    TierView v;
    tier_view(n, v);
    if (v.kind == TierView::K_CONST) return v.k.t == T_FLT;
    if (v.kind != TierView::K_LOCAL || v.flag) return false;
    auto it = reg_of.find(v.slot);
    if (it != reg_of.end()) return is_flt(it->second);
    return !declared.count(v.slot) && entry_kind(v.slot) == 1;
  }
  // `t[k] = v`, the interpreter's store into a table at an integer key (SetIndexArr). The key, then the value: an integer or a float, a nil or
  // a boolean constant, or a copy of another table's element (a nil there is a deopt). The store needs the table to have no metatable and
  // the key in 1..asize; the element takes the value's tag and payload, and the table's cache of absent metamethods is cleared, as the
  // interpreter's set_int clears it. A store that grows the table, or into the hash part, is a deopt.
  bool setindex(const TierView& v) {
    int td = table_of(v.kids[0]);
    if (td < 0) return false;
    if (expr(v.kids[1]) != TY_INT) return fail("a store at a key that is not an integer expression");
    a.push_rax();
    TierView vv;
    tier_view(v.kids[2], vv);
    if (vv.kind == TierView::K_INDEX) {
      int ts = table_of(vv.kids[0]);
      if (ts < 0) return false;
      if (expr(vv.kids[1]) != TY_INT) return fail("a table read at a key that is not an integer expression");
      if (!elem_addr(ts)) return false;
      a.movzx_eax_mem8(RCX);
      a.test_eax_eax();
      if (!tdeopt(CC_E)) return false;  // a nil: a hole, or a lookup that a metatable could answer
      a.mov_rr_pub(R8, RAX);
      a.load64_mem(R9, RCX, 8);
    } else if (vv.kind == TierView::K_CONST && (vv.k.t == T_NIL || vv.k.t == T_TRUE || vv.k.t == T_FALSE)) {
      a.mov_imm(R8, vv.k.t == T_NIL ? 0 : vv.k.t == T_TRUE ? 2 : 1);  // the tags: nil 0, false 1, true 2
      a.mov_imm(R9, 0);
    } else {
      int tv = expr(v.kids[2]);
      if (tv == TY_NONE) return false;
      a.mov_rr_pub(R9, RAX);
      a.mov_imm(R8, tv == TY_FLT ? T_FLT : T_INT);
    }
    a.pop_rax();  // the key
    a.load(RDX, td);
    a.cmp64_mem_imm0(RDX, kTableOff.meta);
    if (!tdeopt(CC_NE)) return false;  // a metatable: __newindex may apply
    a.mov_rr_pub(R10, RAX);
    a.sub_r_imm8(R10, 1);
    a.load32_mem(RCX, RDX, kTableOff.asize);
    a.cmp_rr(R10, RCX);
    if (!tdeopt(CC_AE)) return false;  // outside 1..asize: the hash part, or a grow
    a.load64_mem(RCX, RDX, kTableOff.arr);
    a.shl_r_imm8(R10, 4);
    a.add_rr(RCX, R10);
    a.store8_mem(RCX, 0, R8);
    a.store64_mem(RCX, 8, R9);
    a.store8_imm_mem(RDX, kTableOff.absent, 0);
    return true;
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
    if (is_tab(r)) return failt("a table used as a number");
    a.load(reg, r);
    return is_flt(r) ? TY_FLT : TY_INT;
  }

  // RAX = left, RCX = right (their types in TL and TR). A leaf on either side needs no push: a leaf on the right is loaded into RCX
  // after the left is evaluated, and a leaf on the left is loaded into RAX after the right is evaluated (its value moved to RCX
  // first). Only two compound operands keep the left value on the machine stack while the right one is computed.
  bool binary(Node* l, Node* r, int& tl, int& tr) {
    if (leaf(r)) {
      tl = expr_hint(l, is_float_leaf(r));
      if (tl == TY_NONE) return false;
      tr = leaf_into(r, RCX);
      return tr != TY_NONE;
    }
    if (leaf(l)) {
      tr = expr_hint(r, is_float_leaf(l));
      if (tr == TY_NONE) return false;
      a.mov_rcx_rax();
      tl = leaf_into(l, RAX);
      return tl != TY_NONE;
    }
    tl = expr_hint(l, is_float_leaf(r));
    if (tl == TY_NONE) return false;
    a.push_rax();
    tr = expr_hint(r, is_float_leaf(l));
    if (tr == TY_NONE) return false;
    a.mov_rcx_rax();
    a.pop_rax();
    return true;
  }

  // The deopt sites (see Code::Site). A site is made for the innermost unit at the operation being generated; its number is returned
  // (0 with the failure recorded). TABLE: the site is one of a table operation, which the interpreter completes (a statement or a
  // condition continues); else the operation raises its error in the interpreter (a zero divisor). The locals written back are those of
  // reg_of now (the live-ins seen so far; the rest are added at the end), except the tables, which the frame holds.
  int new_site(bool table) {
    if (units.empty()) {  // not reached: every operation is inside a unit
      fail("internal: an operation outside a unit");
      return 0;
    }
    Code::Site s;
    Unit& u = units.back();
    s.node = u.node;
    if (!table || u.kind == U_EXPR) {
      if (table) {
        fail("internal: a table operation in an expression that is a unit of its own");
        return 0;
      }
      s.kind = Code::Site::RAISE;
      s.stmt = u.kind == U_STMT;
    } else if (u.kind == U_STMT) {
      if (u.entry == 0) {
        entries.push_back(u.cont);
        u.entry = static_cast<int>(entries.size());
      }
      s.kind = Code::Site::STMT;
      s.entry = u.entry;
    } else {
      if (u.entry_t == 0) {
        int st = a.label(), sf = a.label();
        cond_stubs.push_back(CondStub{st, u.jump_if ? u.target : u.fall});
        cond_stubs.push_back(CondStub{sf, u.jump_if ? u.fall : u.target});
        entries.push_back(st);
        u.entry_t = static_cast<int>(entries.size());
        entries.push_back(sf);
        u.entry_f = static_cast<int>(entries.size());
      }
      s.kind = Code::Site::COND;
      s.entry = u.entry_t;
      s.entry_false = u.entry_f;
    }
    for (const auto& kv : reg_of) {
      if (is_tab(kv.second)) continue;
      s.bail_slots.push_back(kv.first);
      s.bail_regs.push_back(kv.second);
    }
    sites.push_back(s);
    stubs.push_back(a.label());
    return static_cast<int>(sites.size());
  }

  // Leaves the code at site K when the flags satisfy CC (CC < 0: always): the values pushed so far are dropped, EAX = K, and the code goes
  // to the stub of the site, which writes the registers back.
  void deopt_jump(int cc, int k) {
    int ok = a.label();
    if (cc >= 0) a.jcc(cc ^ 1, ok);
    if (a.pushes() > 0) a.add_rsp(a.pushes());
    a.mov_eax_imm(static_cast<std::uint32_t>(k));
    a.jmp(stubs[static_cast<std::size_t>(k - 1)]);
    a.bind(ok);
  }

  // A zero divisor in RCX leaves the code (the operation raises in the interpreter).
  void zero_check() {
    int k = new_site(false);
    if (!k) return;
    a.test_rcx_rcx();
    deopt_jump(CC_E, k);
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
    Unit u = make_unit(n, U_COND);
    u.jump_if = jump_if ? 1 : 0;
    u.target = target;
    u.fall = a.label();
    int fall = u.fall;
    units.push_back(u);
    bool saved = tab_ok;
    tab_ok = true;
    bool r = branch_(n, jump_if, target);
    tab_ok = saved;
    units.pop_back();
    a.bind(fall);  // the code after the condition: where a false condition (a true one, for jump_if false) goes on
    return r;
  }

  // A numeric expression that is a unit of its own (the start and the limit of a for loop): its value is in RAX, its type is returned.
  // It raises its errors and reads no table element (a table element read is a deopt that goes on, which this unit cannot).
  int num_unit(Node* n) {
    units.push_back(make_unit(n, U_EXPR));
    bool saved = tab_ok;
    tab_ok = false;
    int t = expr(n);
    tab_ok = saved;
    units.pop_back();
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
      case TierView::K_INDEX: {  // a table element: its truth. A nil (a hole, or a lookup that a metatable could answer) leaves the code
        int tr = table_of(v.kids[0]);
        if (tr < 0) return false;
        if (expr(v.kids[1]) != TY_INT) return fail("a table read at a key that is not an integer expression");
        if (!elem_addr(tr)) return false;
        a.movzx_eax_mem8(RCX);
        int true_l = a.label(), false_l = a.label(), end = a.label();
        a.cmp_eax_imm8(T_TRUE);
        a.jcc(CC_AE, true_l);  // a tag of true, a number, a string, ...: a true value
        a.cmp_eax_imm8(T_FALSE);
        a.jcc(CC_E, false_l);
        if (!tdeopt(-1)) return false;  // nil
        a.bind(true_l);
        if (jump_if) a.jmp(target);
        else a.jmp(end);
        a.bind(false_l);
        if (!jump_if) a.jmp(target);
        a.bind(end);
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
        for (Node* k : v.kids)
          if (!stmt(k)) return false;
        return true;
      case TierView::K_DECL:
      case TierView::K_ASSIGN: {  // a unit of its own: its stores come after all its operands (a deopt runs the statement again)
        units.push_back(make_unit(n, U_STMT));
        units.back().cont = a.label();
        bool saved = tab_ok;
        tab_ok = false;  // a table element read into a local is refused (see index_value)
        bool r = v.kind == TierView::K_DECL ? decl(v) : assign(v);
        tab_ok = saved;
        int cont = units.back().cont;
        units.pop_back();
        a.bind(cont);
        return r;
      }
      case TierView::K_SETINDEX: {  // a table store: a unit of its own, and a deopt of it goes on after it (see setindex)
        units.push_back(make_unit(n, U_STMT));
        units.back().cont = a.label();
        bool saved = tab_ok;
        tab_ok = true;
        bool r = setindex(v);
        tab_ok = saved;
        int cont = units.back().cont;
        units.pop_back();
        a.bind(cont);
        return r;
      }
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
    if (v.multi_last || v.kids.size() != v.slots.size()) return fail("a local declared without one value per name");
    if (v.slots.size() == 1) {  // one local: its value goes straight to its register
      int t = expr(v.kids[0]);
      if (t == TY_NONE) return false;
      int r = declare_reg(v.slots[0], t);
      if (r < 0) return false;
      a.store(r, RAX);
      seen.insert(v.slots[0]);
      return true;
    }
    std::vector<int> ts;
    for (Node* k : v.kids) {
      int t = expr(k);
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
    if (is_tab(r)) return fail("an assignment to a table local");
    if ((t == TY_FLT) != is_flt(r)) return fail("an assignment that changes the type of a local (an integer and a float)");
    a.store(r, RAX);
    return true;
  }

  bool assign(const TierView& v) {
    if (v.captured) return fail("an assignment to a captured local, an upvalue, a global or a field");
    for (int t : v.tkinds)
      if (t != TierView::T_LOCAL) return fail("an assignment to a captured local, an upvalue, a global or a field");
    if (v.multi_last || v.kids.size() != v.slots.size()) return fail("an assignment of other than one value per target");
    if (v.slots.size() == 1) {  // one target: its value goes straight to its word
      int t = expr(v.kids[0]);
      if (t == TY_NONE) return false;
      int r = slot_reg(v.slots[0], true);
      if (r < 0) return false;
      return store_typed(r, t);
    }
    std::vector<int> ts;
    for (Node* k : v.kids) {
      int t = expr(k);
      if (t == TY_NONE) return false;
      ts.push_back(t);
      a.push_rax();
    }
    for (std::size_t i = v.slots.size(); i-- > 0;) {
      a.pop_rax();
      int r = slot_reg(v.slots[i], true);
      if (r < 0) return false;
      if (!store_typed(r, ts[i])) return false;
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
  // The entries (see Code::Site): the prologue jumps to the dispatch at the end of the code, which goes to the top of the loop (entry 0)
  // or to the continuation of the entry ESI holds.
  int dispatch = g.a.label(), top0 = g.a.label();
  g.a.jmp(dispatch);
  g.a.bind(top0);
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
  // Every allocated word goes back to REGS, so that the code can be entered again from any site (the entries reload them).
  for (std::size_t k = 0; k < g.sites.size(); ++k) {
    g.a.bind(g.stubs[k]);
    for (int w = 0; w < g.nregs; ++w) g.a.spill(w);
    g.a.restore_ret();
  }
  for (const Gen::CondStub& cs : g.cond_stubs) {
    g.a.bind(cs.label);
    g.a.jmp(cs.target);
  }
  g.a.bind(dispatch);
  for (std::size_t e = 0; e < g.entries.size(); ++e) {
    g.a.cmp_esi_imm32(static_cast<std::uint32_t>(e + 1));
    g.a.jcc(CC_E, g.entries[e]);
  }
  g.a.jmp(top0);
  return g.ok;
}

}  // namespace
#endif  // NFCAST_JIT_X64

std::unique_ptr<Code> compile(Node* loop, int kind, const Frame& f, std::string& why) {
#if NFCAST_JIT_X64
  if (!value_layout_ok()) {
    why = "the layout of a value is not the one the JIT reads (a tag byte, then the payload at 8)";
    return nullptr;
  }
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
  code->reg_float = g.flt;
  code->reg_tab = g.tab;
  code->sites = g.sites;
  for (Code::Site& s : code->sites) {  // the live-ins are written back at every site, whether they were seen before it or not
    for (std::size_t k = 0; k < g.in_slots.size(); ++k) {
      if (g.tab[static_cast<std::size_t>(g.in_regs[k])]) continue;  // a table: the frame holds it
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
  code->fn = reinterpret_cast<int (*)(std::int64_t*, int)>(reinterpret_cast<std::uintptr_t>(mem));
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
