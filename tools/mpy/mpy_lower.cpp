// .mpy bytecode -> Path B IR (docs/notes/mpy-pathb.md). The subset: small ints, None/bool, names, locals, the operators,
// jumps, calls of functions (positional arguments; no defaults, keywords or *args), closures (cell and free variables,
// LOAD_DEREF, STORE_DEREF, MAKE_CLOSURE), and return. Anything else is refused by name, and no IR is produced for a
// refused module.
//
// Each code object becomes one IR function. The stack is slots stk.N (one per depth) and the locals are loc.N. The module
// body is mpy_module(). A function is mpy_fn_K(ret, args, nargs): it copies its arguments into its locals and stores the
// result through ret. mpy_dispatch(K, ret, args, nargs) calls mpy_fn_K, so the runtime can call a function object by its
// number. The IR never builds an argument array: the runtime keeps a value stack (mpy_push, mpy_call).
//
// Closures follow MicroPython's layout (py/compile.c, py/objclosure.c). A closure's captured cells come first among the
// function's arguments: its free variables are its first n_free locals, and the prelude counts them in n_pos_args. The
// runtime pushes the captured cells before the arguments, so the IR function needs no special case. A cell variable the
// function owns is listed in the prelude; the prologue boxes it in a heap cell (mpy_make_cell).
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

[[noreturn]] void refused(const std::string &what) { throw std::runtime_error("refused: " + what); }

// One instruction of the subset: its kind, and the operand the bytecode carries.
struct Op {
  size_t offset = 0;
  size_t next = 0;      // the offset after it
  std::string kind;     // LOAD_SMALL, LOAD_NONE, CALL, ... (names of the subset)
  long long arg = 0;    // a value, a qstr index, a local, an operator, a child index, a call's argument count, or a target
  long long extra = 0;  // MAKE_CLOSURE: the number of captured cells, which are on the stack below it
};

// The instructions of a code object, with the operand of each packed opcode taken from its opcode byte.
std::vector<Op> normalize(const std::vector<Insn> &insns) {
  std::vector<Op> out;
  for (const Insn &in : insns) {
    Op op;
    op.offset = in.offset;
    op.next = in.offset + in.size;
    unsigned o = in.opcode;
    if (o >= 0x70 && o < 0xb0) {
      op.kind = "LOAD_SMALL";
      op.arg = (long long)o - 0x70 - 16;   // MP_BC_LOAD_CONST_SMALL_INT_MULTI_EXCESS
    } else if (o >= 0xb0 && o < 0xc0) {
      op.kind = "LOAD_LOCAL";              // MP_BC_LOAD_FAST_MULTI, 16 locals
      op.arg = (long long)o - 0xb0;
    } else if (o >= 0xc0 && o < 0xd0) {
      op.kind = "STORE_LOCAL";             // MP_BC_STORE_FAST_MULTI
      op.arg = (long long)o - 0xc0;
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
    } else if (o == opcode("LOAD_FAST_N")) {
      op.kind = "LOAD_LOCAL";
      op.arg = in.arg;
    } else if (o == opcode("STORE_FAST_N")) {
      op.kind = "STORE_LOCAL";
      op.arg = in.arg;
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
    } else if (o == opcode("ROT_THREE")) {
      op.kind = "ROT_THREE";
    } else if (o == opcode("JUMP_IF_TRUE_OR_POP")) {
      op.kind = "JUMP_IF_TRUE_OR_POP";     // a jump keeps the value; the fall-through drops it
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("JUMP_IF_FALSE_OR_POP")) {
      op.kind = "JUMP_IF_FALSE_OR_POP";
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("MAKE_FUNCTION")) {
      op.kind = "MAKE_FUNCTION";           // the argument is the index of the child code object
      op.arg = in.arg;
    } else if (o == opcode("MAKE_CLOSURE")) {
      op.kind = "MAKE_CLOSURE";            // the argument is the child's index; the extra byte is the number of cells
      op.arg = in.arg;
      op.extra = in.extra;
    } else if (o == opcode("MAKE_CLOSURE_DEFARGS")) {
      refused("default arguments of a nested function (MAKE_CLOSURE_DEFARGS) are not lowered yet");
    } else if (o == opcode("LOAD_DEREF")) {
      op.kind = "LOAD_DEREF";              // a cell or free variable: the argument is its local index
      op.arg = in.arg;
    } else if (o == opcode("STORE_DEREF")) {
      op.kind = "STORE_DEREF";
      op.arg = in.arg;
    } else if (o == opcode("DELETE_DEREF")) {
      refused("del of a closure variable (DELETE_DEREF) is not lowered yet");
    } else if (o == opcode("CALL_FUNCTION")) {
      if ((in.arg >> 8) != 0) refused("keyword arguments in a call are not lowered yet");
      op.kind = "CALL";
      op.arg = in.arg;                     // the positional argument count
    } else if (o == opcode("RETURN_VALUE")) {
      op.kind = "RETURN";
    } else {
      char buf[96];
      std::snprintf(buf, sizeof buf, "opcode 0x%02x is not lowered yet (offset %zu)", o, in.offset);
      refused(buf);
    }
    out.push_back(op);
  }
  return out;
}

// The stack effect of an instruction: how many values it adds to the stack (negative when it takes some).
int effect(const Op &op) {
  const std::string &k = op.kind;
  if (k == "LOAD_SMALL" || k == "LOAD_NONE" || k == "LOAD_FALSE" || k == "LOAD_TRUE" || k == "LOAD_NAME" ||
      k == "LOAD_LOCAL" || k == "LOAD_DEREF" || k == "DUP_TOP" || k == "MAKE_FUNCTION")
    return 1;
  if (k == "CALL") return -(int)op.arg;   // the function and its arguments go, the result comes
  if (k == "MAKE_CLOSURE") return 1 - (int)op.extra;   // the captured cells go, the closure comes
  if (k == "STORE_NAME" || k == "STORE_LOCAL" || k == "STORE_DEREF" || k == "POP_TOP" || k == "BINARY" ||
      k == "JUMP_IF_FALSE" || k == "JUMP_IF_TRUE" || k == "JUMP_IF_TRUE_OR_POP" || k == "JUMP_IF_FALSE_OR_POP" ||
      k == "RETURN")
    return -1;   // for the or-pop jumps this is the fall-through; the jump itself keeps the value
  return 0;   // UNARY, ROT_TWO, JUMP
}

std::string lbl(size_t at) { return "\"pc" + std::to_string(at) + "\""; }

class Lowerer {
 public:
  explicit Lowerer(const Module &m) : m_(m) {}

  std::string text(const std::string &source_name) {
    if (m_.top.data.empty()) throw std::runtime_error("mpy: the module has no code");
    size_t nargs = 0;
    std::string module_fn = unit(m_.top, false, "mpy_module", 0, nargs);
    std::ostringstream out;
    out << "(ir-module \"" << source_name << "\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4)"
        << " (double 8) (long_double 16)))\n";
    out << "(producer \"micropython-1.29\")\n";
    out << data_.str();
    out << module_fn;
    for (const std::string &f : fns_) out << f;
    out << dispatch();
    return out.str();
  }

 private:
  // The name of a qstr as a data item, one per distinct name. The module's qstr table is what bytecode operands index.
  std::string name_sym(size_t qidx) {
    if (qidx >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
    const std::string &s = m_.qstrs[qidx];
    auto it = names_.find(s);
    if (it != names_.end()) return it->second;
    std::string sym = "mpy.name." + std::to_string(names_.size());
    names_[s] = sym;
    data_ << "(data \"" << sym << "\" (const (array " << s.size() + 1 << " (const char))) (string \"" << ir_escape(s)
          << "\\000\"))\n";
    return sym;
  }

  // The function number of a child code object, lowering it on first use. n_free is the number of captured cells it takes
  // (MAKE_CLOSURE's operand; 0 for MAKE_FUNCTION), and nargs is its positional argument count without them.
  size_t child(const RawCode &rc, size_t n_free, size_t &nargs) {
    auto it = ids_.find(&rc);
    if (it != ids_.end()) {
      nargs = nargs_[it->second];
      return it->second;
    }
    size_t id = fns_.size();
    fns_.emplace_back();
    nargs_.push_back(0);
    ids_[&rc] = id;
    size_t n = 0;
    std::string f = unit(rc, true, "mpy_fn_" + std::to_string(id), n_free, n);
    fns_[id] = f;
    nargs_[id] = n;
    nargs = n;
    return id;
  }

  // The dispatcher: mpy_dispatch(K, ret, args, nargs) calls mpy_fn_K.
  std::string dispatch() const {
    std::ostringstream out;
    out << "(function \"mpy_dispatch\" (ret void) (params (param %0 \"idx\" unsigned_long) (param %1 \"ret\" (ptr "
        << "unsigned_long)) (param %2 \"args\" (ptr unsigned_long)) (param %3 \"nargs\" unsigned_long))\n";
    size_t n = fns_.size();
    for (size_t k = 0; k < n; ++k) {
      out << "  (let %" << (4 + k) << " bool (eq unsigned_long %0 (const unsigned_long " << k << ")))\n";
    }
    std::string inner;
    for (size_t k = n; k-- > 0;) {
      inner = "(if %" + std::to_string(4 + k) + " (then (eval (call void &\"mpy_fn_" + std::to_string(k) +
              "\" %1 %2 %3))) (else " + inner + "))";
    }
    if (!inner.empty()) out << "  " << inner << "\n";
    out << ")\n";
    return out.str();
  }

  // One code object as an IR function. For a function, its arguments come in through args, and the result goes to ret.
  // n_free is the number of captured cells, which are its first arguments (see the header comment); nargs is set to the
  // positional count the caller passes, without them.
  std::string unit(const RawCode &rc, bool is_fn, const std::string &fname, size_t n_free, size_t &nargs) {
    Prelude pre = read_prelude(rc.data);
    if (!is_fn && pre.n_pos_args) refused("module code with arguments");
    if (pre.n_kwonly_args || pre.n_def_pos_args) refused("keyword or default arguments are not lowered yet");
    if (pre.scope_flags) refused("a generator, *args or **kwargs function is not lowered yet");
    if (pre.n_pos_args > pre.n_state) refused("a function with more arguments than locals");
    if (n_free > pre.n_pos_args) refused("a closure with more captured cells than arguments");
    nargs = pre.n_pos_args - n_free;
    // The cell variables this function owns: the local index of each (the prelude's cell list).
    std::vector<size_t> cells;
    for (size_t i = 0; i < pre.n_cell; ++i) {
      size_t c = rc.data[pre.cells_offset + i];
      if (c >= pre.n_state) throw std::runtime_error("mpy: cell index out of range");
      cells.push_back(c);
    }
    std::vector<uint8_t> code(rc.data.begin() + (long)pre.code_offset, rc.data.end());
    std::vector<Op> ops = normalize(decode_code(code.data(), code.size()));

    // The depth before each instruction, from the stack effects. A jump target must agree on it.
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
      int after = d + effect(op);
      if (after < 0) throw std::runtime_error("mpy: stack underflow");
      // (successor, depth there). A jump-or-pop keeps its value when it jumps, so the target is at depth d.
      std::vector<std::pair<size_t, int>> succ;
      if (op.kind == "RETURN") {
        // nothing follows
      } else if (op.kind == "JUMP") {
        succ.push_back({(size_t)op.arg, after});
      } else if (op.kind == "JUMP_IF_FALSE" || op.kind == "JUMP_IF_TRUE") {
        succ.push_back({(size_t)op.arg, after});
        succ.push_back({op.next, after});
      } else if (op.kind == "JUMP_IF_FALSE_OR_POP" || op.kind == "JUMP_IF_TRUE_OR_POP") {
        succ.push_back({(size_t)op.arg, d});
        succ.push_back({op.next, after});
      } else {
        succ.push_back({op.next, after});
      }
      for (const auto &[s, sd] : succ) {
        if (s >= code.size()) throw std::runtime_error("mpy: a jump leaves the code");
        auto it = depth.find(s);
        if (it == depth.end()) {
          depth[s] = sd;
          work.push_back(s);
        } else if (it->second != sd) {
          throw std::runtime_error("mpy: stack depth differs at a join");
        }
      }
    }
    int max_depth = 0;
    for (const Op &op : ops) {
      auto it = depth.find(op.offset);
      if (it != depth.end()) {
        int hi = it->second + (effect(op) > 0 ? effect(op) : 0);
        if (hi > max_depth) max_depth = hi;
      }
    }

    int next = is_fn ? 3 : 0;   // %0..%2 are the parameters of a function
    std::ostringstream body;
    auto fresh = [&]() { return "%" + std::to_string(next++); };
    auto slot = [](const std::string &kind, int i) { return "$\"" + kind + "." + std::to_string(i) + "\""; };
    auto push = [&](int d, const std::string &value) {
      body << "  (store unsigned_long " << slot("stk", d) << " " << value << ")\n";
    };
    auto load = [&](int s) {
      std::string r = fresh();
      body << "  (let " << r << " unsigned_long (load unsigned_long " << slot("stk", s) << "))\n";
      return r;
    };
    auto pop = [&](int d) { return load(d - 1); };
    auto local = [&](long long i) {
      if (i < 0 || i >= (long long)pre.n_state) throw std::runtime_error("mpy: local out of range");
      return slot("loc", (int)i);
    };

    if (is_fn) {
      for (unsigned i = 0; i < pre.n_pos_args; ++i) {
        std::string p = fresh(), v = fresh();
        body << "  (let " << p << " (ptr unsigned_long) (offset %1 " << i * 8 << "))\n";
        body << "  (let " << v << " unsigned_long (load unsigned_long " << p << "))\n";
        body << "  (store unsigned_long " << local(i) << " " << v << ")\n";
      }
    }

    // The prelude's cell list (bc.c mp_setup_code_state): each owned cell variable's slot is boxed in a heap cell. An
    // argument keeps its value in the cell; any other local starts unbound (0), which a read reports.
    for (size_t c : cells) {
      std::string v = fresh(), cell = fresh();
      if (c < pre.n_pos_args) {
        body << "  (let " << v << " unsigned_long (load unsigned_long " << local((long long)c) << "))\n";
      } else {
        body << "  (let " << v << " unsigned_long (const unsigned_long 0))\n";
      }
      body << "  (let " << cell << " unsigned_long (call unsigned_long &\"mpy_make_cell\" " << v << "))\n";
      body << "  (store unsigned_long " << local((long long)c) << " " << cell << ")\n";
    }

    for (const Op &op : ops) {
      auto dit = depth.find(op.offset);
      if (dit == depth.end()) continue;   // unreachable code emits nothing
      int d = dit->second;
      body << "  (label " << lbl(op.offset) << ")\n";
      const std::string &k = op.kind;
      if (k == "LOAD_SMALL") {
        push(d, "(const unsigned_long " + std::to_string(small_word(op.arg)) + ")");
      } else if (k == "LOAD_NONE") {
        push(d, "(const unsigned_long 6)");
      } else if (k == "LOAD_FALSE") {
        push(d, "(const unsigned_long 14)");
      } else if (k == "LOAD_TRUE") {
        push(d, "(const unsigned_long 22)");
      } else if (k == "LOAD_NAME") {
        std::string sym = name_sym((size_t)op.arg);
        size_t len = m_.qstrs[(size_t)op.arg].size();
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_load_name\" @\"" << sym
             << "\" (const unsigned_long " << len << ")))\n";
        push(d, r);
      } else if (k == "STORE_NAME") {
        std::string sym = name_sym((size_t)op.arg);
        size_t len = m_.qstrs[(size_t)op.arg].size();
        std::string v = pop(d);
        body << "  (eval (call void &\"mpy_store_name\" @\"" << sym << "\" (const unsigned_long " << len << ") " << v
             << "))\n";
      } else if (k == "LOAD_LOCAL") {
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (load unsigned_long " << local(op.arg) << "))\n";
        push(d, r);
      } else if (k == "STORE_LOCAL") {
        std::string v = pop(d);
        body << "  (store unsigned_long " << local(op.arg) << " " << v << ")\n";
      } else if (k == "POP_TOP") {
        pop(d);
      } else if (k == "DUP_TOP") {
        std::string v = pop(d);
        push(d, v);   // the copy goes on top; the original is still in the slot below it
      } else if (k == "ROT_TWO") {
        // pop(d) takes the top (slot d-1), pop(d-1) the one below it (slot d-2); the top goes below after the rotation.
        std::string top = pop(d), below = pop(d - 1);
        push(d - 2, top);
        push(d - 1, below);
      } else if (k == "BINARY") {
        std::string b = pop(d), a = pop(d - 1);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_binop\" (const int " << op.arg << ") " << a
             << " " << b << "))\n";
        push(d - 2, r);   // two operands came off; the result takes the slot of the left one
      } else if (k == "UNARY") {
        std::string a = pop(d);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_unop\" (const int " << op.arg << ") " << a
             << "))\n";
        push(d - 1, r);
      } else if (k == "LOAD_DEREF") {
        // A cell or free variable: its local holds the cell, and the value is read through it.
        std::string cell = fresh(), r = fresh();
        body << "  (let " << cell << " unsigned_long (load unsigned_long " << local(op.arg) << "))\n";
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_cell_get\" " << cell << "))\n";
        push(d, r);
      } else if (k == "STORE_DEREF") {
        std::string v = pop(d), cell = fresh();
        body << "  (let " << cell << " unsigned_long (load unsigned_long " << local(op.arg) << "))\n";
        body << "  (eval (call void &\"mpy_cell_set\" " << cell << " " << v << "))\n";
      } else if (k == "MAKE_FUNCTION") {
        if ((size_t)op.arg >= rc.children.size()) throw std::runtime_error("mpy: child index out of range");
        size_t n = 0;
        size_t id = child(rc.children[(size_t)op.arg], 0, n);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_make_function\" (const unsigned_long " << id
             << ") (const unsigned_long " << n << ")))\n";
        push(d, r);
      } else if (k == "MAKE_CLOSURE") {
        // The captured cells are the raw slots LOAD_FAST pushed (below the closure's stack position). They go on the runtime
        // value stack, where mpy_make_closure takes them, as the arguments of a call do.
        if ((size_t)op.arg >= rc.children.size()) throw std::runtime_error("mpy: child index out of range");
        int nc = (int)op.extra;
        size_t n = 0;
        size_t id = child(rc.children[(size_t)op.arg], (size_t)nc, n);
        for (int i = 0; i < nc; ++i) {
          std::string v = load(d - nc + i);
          body << "  (eval (call void &\"mpy_push\" " << v << "))\n";
        }
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_make_closure\" (const unsigned_long " << id
             << ") (const unsigned_long " << n << ") (const unsigned_long " << nc << ")))\n";
        push(d - nc, r);
      } else if (k == "CALL") {
        int n = (int)op.arg;
        for (int i = 0; i < n; ++i) {
          std::string v = load(d - n + i);
          body << "  (eval (call void &\"mpy_push\" " << v << "))\n";
        }
        std::string f = load(d - n - 1);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_call\" " << f << " (const unsigned_long " << n
             << ")))\n";
        push(d - n - 1, r);
      } else if (k == "JUMP_IF_FALSE" || k == "JUMP_IF_TRUE") {
        std::string v = pop(d);
        std::string t = fresh(), c = fresh();
        body << "  (let " << t << " int (call int &\"mpy_truth\" " << v << "))\n";
        body << "  (let " << c << " bool (ne int " << t << " (const int 0)))\n";
        if (k == "JUMP_IF_FALSE") {
          body << "  (if " << c << " (then) (else (goto " << lbl((size_t)op.arg) << ")))\n";
        } else {
          body << "  (if " << c << " (then (goto " << lbl((size_t)op.arg) << ")) (else))\n";
        }
      } else if (k == "ROT_THREE") {
        // bottom to top s0 s1 s2 becomes s2 s0 s1
        std::string s2 = load(d - 1), s1 = load(d - 2), s0 = load(d - 3);
        push(d - 3, s2);
        push(d - 2, s0);
        push(d - 1, s1);
      } else if (k == "JUMP_IF_FALSE_OR_POP" || k == "JUMP_IF_TRUE_OR_POP") {
        std::string v = load(d - 1);   // the value stays for the jump; the fall-through drops it (depth only)
        std::string t = fresh(), c = fresh();
        body << "  (let " << t << " int (call int &\"mpy_truth\" " << v << "))\n";
        body << "  (let " << c << " bool (ne int " << t << " (const int 0)))\n";
        if (k == "JUMP_IF_FALSE_OR_POP") {
          body << "  (if " << c << " (then) (else (goto " << lbl((size_t)op.arg) << ")))\n";
        } else {
          body << "  (if " << c << " (then (goto " << lbl((size_t)op.arg) << ")) (else))\n";
        }
      } else if (k == "JUMP") {
        body << "  (goto " << lbl((size_t)op.arg) << ")\n";
      } else if (k == "RETURN") {
        std::string v = pop(d);
        if (is_fn) body << "  (store unsigned_long %0 " << v << ")\n";
        body << "  (return)\n";
      } else {
        throw std::runtime_error("mpy: internal: kind not handled: " + k);
      }
    }

    std::ostringstream out;
    out << "(function \"" << fname << "\" (ret void) "
        << (is_fn ? "(params (param %0 \"ret\" (ptr unsigned_long)) (param %1 \"args\" (ptr unsigned_long)) "
                    "(param %2 \"nargs\" unsigned_long))"
                  : "(params)")
        << "\n";
    for (int d = 0; d <= max_depth; ++d) out << "  (slot \"stk." << d << "\" unsigned_long 8 8)\n";
    for (unsigned i = 0; i < pre.n_state; ++i) out << "  (slot \"loc." << i << "\" unsigned_long 8 8)\n";
    out << body.str() << ")\n";
    return out.str();
  }

  const Module &m_;
  std::ostringstream data_;
  std::map<std::string, std::string> names_;
  std::map<const RawCode *, size_t> ids_;
  std::vector<std::string> fns_;   // the IR of each child function, by number
  std::vector<size_t> nargs_;      // and each one's positional argument count
};

}  // namespace

std::string lower_module_text(const Module &m, const std::string &source_name) {
  Lowerer lowerer(m);
  return lowerer.text(source_name);
}

}  // namespace mpy
