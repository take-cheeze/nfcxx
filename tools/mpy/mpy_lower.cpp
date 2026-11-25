// .mpy top-level code -> Path B IR (docs/notes/mpy-pathb.md). The first slice: integer and None/bool constants, names,
// integer operators, comparisons, jumps and return, in the module's own code. A function, a class, or any opcode outside
// this slice is refused by name, and no IR is produced for a refused module.
//
// The stack machine becomes IR: each stack depth d is a slot stk.d holding one word. The depth before each instruction
// is computed first, from the stack effect of the instructions, so every instruction knows the slots it reads and writes.
#include "mpy_lower.hpp"

#include <cstdio>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "mpy_opcodes.inc"

namespace mpy {

namespace {

// The opcode values, by name (bc0.h).
unsigned opcode(const char *name) {
  for (const auto &e : kOpNames) {
    if (std::string(e.name) == name) return e.value;
  }
  throw std::runtime_error(std::string("mpy: no opcode named ") + name);
}

// The tagged word of a small int (MICROPY_OBJ_REPR_A): (v << 1) | 1.
unsigned long long small_word(long long v) { return ((unsigned long long)v << 1) | 1ULL; }

std::string ir_escape(const std::string &s) {
  std::string out;
  char buf[8];
  for (unsigned char ch : s) {
    if (ch == '"' || ch == '\\') {
      out += '\\';
      out += static_cast<char>(ch);
    } else if (ch >= 0x20 && ch < 0x7f) {
      out += static_cast<char>(ch);
    } else {
      std::snprintf(buf, sizeof buf, "\\%03o", ch);
      out += buf;
    }
  }
  return out;
}

// One decoded instruction of the slice: the kind, and the operand that the bytecode carries.
struct Op {
  size_t offset = 0;
  size_t next = 0;                 // the offset after it
  std::string kind;                // LOAD_SMALL, LOAD_NONE, ... (names of the slice)
  long long arg = 0;               // the operand: a value, a qstr index, an operator, or a jump target
};

// Normalizes the bytecode: the packed opcodes get their operand from the opcode byte (bc0.h, persistentcode.c).
std::vector<Op> normalize(const std::vector<Insn> &insns, const std::vector<std::string> &qstrs) {
  (void)qstrs;
  std::vector<Op> out;
  for (const Insn &in : insns) {
    Op op;
    op.offset = in.offset;
    op.next = in.offset + in.size;
    unsigned o = in.opcode;
    if (o >= 0x70 && o < 0xb0) {
      op.kind = "LOAD_SMALL";
      op.arg = (long long)o - 0x70 - 16;   // MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS
    } else if (o >= 0xd0 && o < 0xd7) {
      op.kind = "UNARY";
      op.arg = (long long)o - 0xd0;
    } else if (o >= 0xd7) {
      op.kind = "BINARY";
      op.arg = (long long)o - 0xd7;
    } else if (o == opcode("LOAD_CONST_SMALL_INT")) {
      op.kind = "LOAD_SMALL";
      op.arg = in.arg;
    } else if (o == opcode("LOAD_CONST_NONE")) {
      op.kind = "LOAD_NONE";
    } else if (o == opcode("LOAD_CONST_FALSE")) {
      op.kind = "LOAD_FALSE";
    } else if (o == opcode("LOAD_CONST_TRUE")) {
      op.kind = "LOAD_TRUE";
    } else if (o == opcode("LOAD_NAME") || o == opcode("LOAD_GLOBAL")) {
      op.kind = "LOAD_NAME";
      op.arg = in.arg;
    } else if (o == opcode("STORE_NAME") || o == opcode("STORE_GLOBAL")) {
      op.kind = "STORE_NAME";
      op.arg = in.arg;
    } else if (o == opcode("POP_TOP")) {
      op.kind = "POP_TOP";
    } else if (o == opcode("DUP_TOP")) {
      op.kind = "DUP_TOP";
    } else if (o == opcode("ROT_TWO")) {
      op.kind = "ROT_TWO";
    } else if (o == opcode("POP_JUMP_IF_FALSE")) {
      op.kind = "JUMP_IF_FALSE";
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("POP_JUMP_IF_TRUE")) {
      op.kind = "JUMP_IF_TRUE";
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("JUMP")) {
      op.kind = "JUMP";
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("RETURN_VALUE")) {
      op.kind = "RETURN";
    } else {
      char buf[96];
      std::snprintf(buf, sizeof buf, "refused: opcode 0x%02x is not lowered yet (offset %zu)", o, in.offset);
      throw std::runtime_error(buf);
    }
    out.push_back(op);
  }
  return out;
}

// The stack effect of a kind, and the depth it leaves at its successors (the jump target of a jump, too).
int effect(const std::string &kind) {
  if (kind == "LOAD_SMALL" || kind == "LOAD_NONE" || kind == "LOAD_FALSE" || kind == "LOAD_TRUE" ||
      kind == "LOAD_NAME" || kind == "DUP_TOP") return 1;
  if (kind == "STORE_NAME" || kind == "POP_TOP" || kind == "BINARY" || kind == "JUMP_IF_FALSE" ||
      kind == "JUMP_IF_TRUE" || kind == "RETURN") return -1;
  return 0;   // UNARY, ROT_TWO, JUMP
}

}  // namespace

std::string lower_module_text(const Module &m, const std::string &source_name) {
  if (m.top.data.empty()) throw std::runtime_error("mpy: the module has no code");
  Prelude pre = read_prelude(m.top.data);
  if (pre.n_pos_args || pre.n_kwonly_args) throw std::runtime_error("refused: module code with arguments");
  std::vector<uint8_t> code(m.top.data.begin() + (long)pre.code_offset, m.top.data.end());
  std::vector<Op> ops = normalize(decode_code(code.data(), code.size()), m.qstrs);

  // The depth before each instruction (offsets are the keys), from the stack effects; a jump target must agree.
  std::map<size_t, int> depth;
  std::map<size_t, size_t> index;
  for (size_t i = 0; i < ops.size(); ++i) index[ops[i].offset] = i;
  std::vector<size_t> work{0};
  depth[0] = 0;
  while (!work.empty()) {
    size_t at = work.back();
    work.pop_back();
    if (!index.count(at)) throw std::runtime_error("mpy: a jump lands between instructions");
    const Op &op = ops[index[at]];
    int d = depth[at];
    int after = d + effect(op.kind);
    if (after < 0) throw std::runtime_error("mpy: stack underflow");
    std::vector<size_t> succ;
    if (op.kind == "RETURN") {
      // nothing follows
    } else if (op.kind == "JUMP") {
      succ.push_back((size_t)op.arg);
    } else if (op.kind == "JUMP_IF_FALSE" || op.kind == "JUMP_IF_TRUE") {
      succ.push_back((size_t)op.arg);
      succ.push_back(op.next);
    } else {
      succ.push_back(op.next);
    }
    for (size_t s : succ) {
      if (s >= code.size()) {
        if (s == code.size() && op.kind != "JUMP" && op.kind != "JUMP_IF_FALSE" && op.kind != "JUMP_IF_TRUE") continue;
        throw std::runtime_error("mpy: a jump leaves the code");
      }
      auto it = depth.find(s);
      if (it == depth.end()) {
        depth[s] = after;
        work.push_back(s);
      } else if (it->second != after) {
        throw std::runtime_error("mpy: stack depth differs at a join");
      }
    }
  }
  int max_depth = 0;
  for (const auto &kv : depth) max_depth = kv.second > max_depth ? kv.second : max_depth;
  // Every depth a value reaches needs a slot: the maximum of the depths before and after each instruction.
  for (const Op &op : ops) {
    auto it = depth.find(op.offset);
    if (it != depth.end()) {
      int hi = it->second + (effect(op.kind) > 0 ? effect(op.kind) : 0);
      if (hi > max_depth) max_depth = hi;
    }
  }

  // Data items: the names of the module, by qstr index.
  std::ostringstream data, body;
  std::map<std::string, std::string> names;
  auto name_sym = [&](size_t qidx) -> std::string {
    if (qidx >= m.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
    const std::string &s = m.qstrs[qidx];
    auto it = names.find(s);
    if (it != names.end()) return it->second;
    std::string sym = "mpy.name." + std::to_string(names.size());
    names[s] = sym;
    data << "(data \"" << sym << "\" (const (array " << s.size() + 1 << " (const char))) (string \"" << ir_escape(s)
         << "\\000\"))\n";
    return sym;
  };

  int next = 0;
  auto fresh = [&]() { return "%" + std::to_string(next++); };
  auto slot = [](int d) { return "$\"stk." + std::to_string(d) + "\""; };
  auto push = [&](int d, const std::string &value) {
    body << "  (store unsigned_long " << slot(d) << " " << value << ")\n";
  };
  auto pop = [&](int d) {
    std::string r = fresh();
    body << "  (let " << r << " unsigned_long (load unsigned_long " << slot(d - 1) << "))\n";
    return r;
  };
  auto lbl = [](size_t at) { return "\"pc" + std::to_string(at) + "\""; };

  for (const Op &op : ops) {
    auto dit = depth.find(op.offset);
    if (dit == depth.end()) continue;   // unreachable code emits nothing
    int d = dit->second;
    body << "  (label " << lbl(op.offset) << ")\n";
    if (op.kind == "LOAD_SMALL") {
      push(d, "(const unsigned_long " + std::to_string(small_word(op.arg)) + ")");
    } else if (op.kind == "LOAD_NONE") {
      push(d, "(const unsigned_long 6)");
    } else if (op.kind == "LOAD_FALSE") {
      push(d, "(const unsigned_long 14)");
    } else if (op.kind == "LOAD_TRUE") {
      push(d, "(const unsigned_long 22)");
    } else if (op.kind == "LOAD_NAME") {
      std::string sym = name_sym((size_t)op.arg);
      std::string r = fresh();
      body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_load_name\" @\"" << sym << "\" (const unsigned_long "
           << m.qstrs[(size_t)op.arg].size() << ")))\n";
      push(d, r);
    } else if (op.kind == "STORE_NAME") {
      std::string sym = name_sym((size_t)op.arg);
      std::string v = pop(d);
      body << "  (eval (call void &\"mpy_store_name\" @\"" << sym << "\" (const unsigned_long "
           << m.qstrs[(size_t)op.arg].size() << ") " << v << "))\n";
    } else if (op.kind == "POP_TOP") {
      pop(d);
    } else if (op.kind == "DUP_TOP") {
      std::string v = pop(d);
      push(d, v);   // the copy goes on top; the original is still in the slot below it
    } else if (op.kind == "ROT_TWO") {
      // pop(d) takes the top (slot d-1), pop(d-1) the one below it (slot d-2); the top goes below after the rotation.
      std::string top = pop(d), below = pop(d - 1);
      push(d - 2, top);
      push(d - 1, below);
    } else if (op.kind == "BINARY") {
      std::string b = pop(d), a = pop(d - 1);
      std::string r = fresh();
      body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_binop\" (const int " << op.arg << ") " << a
           << " " << b << "))\n";
      push(d - 2, r);   // two operands came off; the result takes the slot of the left one
    } else if (op.kind == "UNARY") {
      std::string a = pop(d);
      std::string r = fresh();
      body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_unop\" (const int " << op.arg << ") " << a
           << "))\n";
      push(d - 1, r);
    } else if (op.kind == "JUMP_IF_FALSE" || op.kind == "JUMP_IF_TRUE") {
      std::string v = pop(d);
      std::string t = fresh(), c = fresh();
      body << "  (let " << t << " int (call int &\"mpy_truth\" " << v << "))\n";
      body << "  (let " << c << " bool (ne int " << t << " (const int 0)))\n";
      if (op.kind == "JUMP_IF_FALSE") {
        body << "  (if " << c << " (then) (else (goto " << lbl((size_t)op.arg) << ")))\n";
      } else {
        body << "  (if " << c << " (then (goto " << lbl((size_t)op.arg) << ")) (else))\n";
      }
    } else if (op.kind == "JUMP") {
      body << "  (goto " << lbl((size_t)op.arg) << ")\n";
    } else if (op.kind == "RETURN") {
      pop(d);
      body << "  (return)\n";
    } else {
      throw std::runtime_error("mpy: internal: kind not handled: " + op.kind);
    }
  }

  std::ostringstream out;
  out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
      << " (double 8) (long_double 16)))\n";
  out << "(producer \"micropython-1.29\")\n";
  out << data.str();
  out << "(function \"mpy_module\" (ret void) (params)\n";
  for (int d = 0; d <= max_depth; ++d) out << "  (slot \"stk." << d << "\" unsigned_long 8 8)\n";
  out << body.str() << ")\n";
  return out.str();
}

}  // namespace mpy
