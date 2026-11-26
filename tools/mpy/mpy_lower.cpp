// .mpy bytecode -> Path B IR (docs/notes/mpy-pathb.md). The subset: small ints, None/bool, str constants, names, locals,
// the operators, jumps, calls of functions (positional arguments; no defaults, keywords or *args), closures (cell and free
// variables, LOAD_DEREF, STORE_DEREF, MAKE_CLOSURE), lists, tuples, dicts (BUILD_MAP, STORE_MAP, and the methods get, keys,
// values, items, pop and update), sets (BUILD_SET), slices, del of an item (LOAD_NULL with STORE_SUBSCR), list, dict and set
// comprehensions (STORE_COMP), and return. Anything else is refused by name,
// and no IR is produced for a refused module.
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
#include <functional>
#include <map>
#include <set>
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

[[noreturn]] void refused(const std::string &what);

// The value of an int constant, which the .mpy file gives as decimal digits. The runtime holds a small int of 62 bits
// (mpy_rt.c), so a constant outside that range is refused, as big ints are.
long long int_constant(const std::string &digits) {
  size_t used = 0;
  long long v = 0;
  try {
    v = std::stoll(digits, &used);
  } catch (const std::exception &) {
    refused("an int constant out of the small-int range is not lowered yet");
  }
  if (used != digits.size() || v > (1LL << 62) - 1 || v < -(1LL << 62)) {
    refused("an int constant out of the small-int range is not lowered yet");
  }
  return v;
}

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

// The name of an opcode (bc0.h), for a refusal.
std::string opname(unsigned o) {
  for (const auto &e : kOpNames) {
    if (e.value == o) return e.name;
  }
  return "?";
}

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
    } else if (o == opcode("LOAD_CONST_STRING")) {
      op.kind = "LOAD_STR";
      op.arg = in.arg;                     // a qstr index
    } else if (o == opcode("LOAD_CONST_OBJ")) {
      op.kind = "LOAD_OBJ";
      op.arg = in.arg;                     // an index into the constant table; only a str is lowered
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
    } else if (o == opcode("LOAD_NAME")) {
      op.kind = "LOAD_NAME";               // a class body's namespace, then the globals (mpy_load_name)
      op.arg = in.arg;
    } else if (o == opcode("LOAD_GLOBAL")) {
      op.kind = "LOAD_GLOBAL";             // the globals, then the builtins (mpy_load_global)
      op.arg = in.arg;
    } else if (o == opcode("STORE_NAME")) {
      op.kind = "STORE_NAME";              // a class body's namespace, else the globals (mpy_store_name)
      op.arg = in.arg;
    } else if (o == opcode("STORE_GLOBAL")) {
      op.kind = "STORE_GLOBAL";
      op.arg = in.arg;
    } else if (o == opcode("SETUP_EXCEPT") || o == opcode("SETUP_FINALLY")) {
      // A try block: the handler is at the target, and its stack has the exception on top of the depth here.
      op.kind = "SETUP";
      op.arg = (long long)op.next + in.arg;
      op.extra = o == opcode("SETUP_FINALLY") ? 1 : 0;   // the kind of block: 1 for a finally, 0 for an except
    } else if (o == opcode("SETUP_WITH")) {
      // A with statement: the context manager is on top. Its exit method goes below it, its __enter__ result on top, and the
      // block is a finally-like one for the reference (its exit runs on the way out, as the unwind of the with block does).
      op.kind = "SETUP_WITH";
      op.arg = (long long)op.next + in.arg;
      op.extra = 2;   // the block kind: 2 for a with (1 for a finally, 0 for an except; see the walk)
    } else if (o == opcode("WITH_CLEANUP")) {
      op.kind = "WITH_CLEANUP";           // the exit method and the context manager below the top (None or an exception)
    } else if (o == opcode("UNWIND_JUMP")) {
      // A break or continue that leaves try blocks: the target is relative to the byte after the offset, which is the extra
      // byte (the number of blocks to leave, and bit 0x80 for a break out of a for loop).
      op.kind = "UNWIND_JUMP";
      op.arg = (long long)op.next - 1 + in.arg;
      op.extra = in.extra;
    } else if (o == opcode("POP_EXCEPT_JUMP")) {
      op.kind = "POP_EXCEPT_JUMP";         // ends the block, then jumps
      op.arg = (long long)op.next + in.arg;
    } else if (o == opcode("END_FINALLY")) {
      op.kind = "END_FINALLY";             // ends the block; None goes on, an exception is raised again
    } else if (o == opcode("DELETE_FAST")) {
      op.kind = "DELETE_LOCAL";            // del of a local, as an except clause's name is deleted: it becomes unbound
      op.arg = in.arg;
    } else if (o == opcode("DELETE_NAME")) {
      op.kind = "DELETE_NAME";             // del of a name in a class body or at module level
      op.arg = in.arg;
    } else if (o == opcode("RAISE_OBJ")) {
      op.kind = "RAISE_OBJ";
    } else if (o == opcode("RAISE_LAST")) {
      op.kind = "RAISE_LAST";              // a bare raise
    } else if (o == opcode("RAISE_FROM")) {
      op.kind = "RAISE_FROM";              // the cause is on top of the exception (the reference drops it, see mpy_raise_from)
    } else if (o == opcode("LOAD_BUILD_CLASS")) {
      op.kind = "BUILD_CLASS";             // the builtin __build_class__, which the class statement calls
    } else if (o == opcode("LOAD_ATTR")) {
      op.kind = "LOAD_ATTR";
      op.arg = in.arg;                     // a qstr
    } else if (o == opcode("STORE_ATTR")) {
      op.kind = "STORE_ATTR";              // the object is on top, the value below it (vm.c)
      op.arg = in.arg;
    } else if (o == opcode("POP_TOP")) {
      op.kind = "POP_TOP";
    } else if (o == opcode("DUP_TOP")) {
      op.kind = "DUP_TOP";
    } else if (o == opcode("ROT_TWO")) {
      op.kind = "ROT_TWO";
    } else if (o == opcode("DUP_TOP_TWO")) {
      op.kind = "DUP_TWO";                 // the top two values are copied on top: a, b becomes a, b, a, b
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
    } else if (o == opcode("BUILD_LIST")) {
      op.kind = "BUILD_LIST";
      op.arg = in.arg;                     // the number of items, taken from the stack
    } else if (o == opcode("BUILD_TUPLE")) {
      op.kind = "BUILD_TUPLE";
      op.arg = in.arg;
    } else if (o == opcode("LOAD_SUBSCR")) {
      op.kind = "LOAD_SUBSCR";
    } else if (o == opcode("STORE_SUBSCR")) {
      op.kind = "STORE_SUBSCR";           // with a null value (LOAD_NULL) it is a del
    } else if (o == opcode("LOAD_NULL")) {
      op.kind = "LOAD_NULL";              // the null a del stores: DELETE_SUBSCR is LOAD_NULL, ROT_THREE, STORE_SUBSCR
    } else if (o == opcode("BUILD_MAP")) {
      op.kind = "BUILD_MAP";              // the operand is the number of items: the table's size (map.c's alloc)
      op.arg = in.arg;
    } else if (o == opcode("STORE_MAP")) {
      op.kind = "STORE_MAP";              // the stack is dict, value, key (key on top); the dict stays
    } else if (o == opcode("BUILD_SLICE")) {
      op.kind = "BUILD_SLICE";
      op.arg = in.arg;                    // 2 or 3: the start, the stop and the step (none when absent)
    } else if (o == opcode("BUILD_SET")) {
      op.kind = "BUILD_SET";              // the number of items, taken from the stack (mp_obj_new_set)
      op.arg = in.arg;
    } else if (o == opcode("STORE_COMP")) {
      // A comprehension's store: the argument is (the collection's offset below the top << 2) | its kind (0 list, 1 dict,
      // 2 set).
      op.kind = "STORE_COMP";
      op.arg = in.arg >> 2;
      op.extra = in.arg & 3;
    } else if (o == opcode("UNPACK_SEQUENCE")) {
      op.kind = "UNPACK_SEQUENCE";
      op.arg = in.arg;
    } else if (o == opcode("GET_ITER_STACK")) {
      op.kind = "GET_ITER";                // a for loop's iterator, which takes kIterSlots stack slots
    } else if (o == opcode("GET_ITER")) {
      refused("GET_ITER outside a for loop is not lowered yet");
    } else if (o == opcode("FOR_ITER")) {
      op.kind = "FOR_ITER";                // the fall-through takes the next value; the jump, taken when exhausted, drops the iterator
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
      op.kind = "DELETE_DEREF";            // del of a cell or free variable: the cell's value becomes unbound (0)
      op.arg = in.arg;
    } else if (o == opcode("CALL_FUNCTION")) {
      if ((in.arg >> 8) != 0) refused("keyword arguments in a call are not lowered yet");
      op.kind = "CALL";
      op.arg = in.arg;                     // the positional argument count
    } else if (o == opcode("LOAD_METHOD")) {
      op.kind = "LOAD_METHOD";             // the argument is the attribute's qstr; only append and pop are lowered (below)
      op.arg = in.arg;
    } else if (o == opcode("LOAD_SUPER_METHOD")) {
      // super().name: the class and the self are on the stack (the super global below them is replaced by the method).
      op.kind = "LOAD_SUPER_METHOD";
      op.arg = in.arg;
    } else if (o == opcode("CALL_METHOD")) {
      if ((in.arg >> 8) != 0) refused("keyword arguments in a call are not lowered yet");
      op.kind = "CALL_METHOD";             // the positional argument count; the method and its self lie below the arguments
      op.arg = in.arg;
    } else if (o == opcode("RETURN_VALUE")) {
      op.kind = "RETURN";
    } else {
      char buf[160];
      std::snprintf(buf, sizeof buf, "opcode %s (0x%02x) is not lowered yet (offset %zu)", opname(o).c_str(), o, in.offset);
      refused(buf);
    }
    out.push_back(op);
  }
  return out;
}

// The methods of the builtin types that the runtime does not have yet (str, list, dict, set, ...): a method call of one of
// these names is refused. A class's method of such a name is refused too, which is the cost of not knowing the receiver's
// type. The dict methods that are lowered (get, keys, values, items, pop, update) are not here.
// The names that a dict or a set has too (copy, clear, setdefault, popitem, fromkeys, add, discard, remove, union, intersection,
// difference) are not refused here: the lowering does not know the receiver's type, so the runtime refuses them on a value
// that is neither a dict nor a set (mpy_load_method, refused_method_name).
const std::set<std::string> kBuiltinMethods = {
    "capitalize", "center", "count", "encode", "endswith", "extend", "find", "format", "index",
    "insert", "isalpha", "isdigit", "isspace", "join", "ljust", "lower", "lstrip", "partition",
    "replace", "reverse", "rfind", "rindex", "rjust", "rstrip", "rsplit", "sort", "split", "splitlines",
    "startswith", "strip", "title", "upper", "zfill"};

// A for loop's iterator takes MP_OBJ_ITER_BUF_NSLOTS stack slots (obj.h: 4 on 32- and 64-bit hosts); its object is in the
// bottom one. break pops all of them.
constexpr int kIterSlots = 4;

// The stack effect of an instruction: how many values it adds to the stack (negative when it takes some).
int effect(const Op &op) {
  const std::string &k = op.kind;
  if (k == "LOAD_SMALL" || k == "LOAD_NONE" || k == "LOAD_FALSE" || k == "LOAD_TRUE" || k == "LOAD_NAME" ||
      k == "LOAD_LOCAL" || k == "LOAD_STR" || k == "LOAD_OBJ" || k == "LOAD_DEREF" || k == "DUP_TOP" ||
      k == "MAKE_FUNCTION" || k == "LOAD_NULL" || k == "BUILD_MAP" || k == "LOAD_GLOBAL" || k == "BUILD_CLASS")
    return 1;
  if (k == "STORE_ATTR") return -2;      // the object and the value go
  if (k == "SETUP_WITH") return 2;       // the exit method goes under the context manager, and __enter__'s value comes on top
  if (k == "WITH_CLEANUP") return -2;    // the top and the context manager go; the result takes the exit method's place
  if (k == "END_FINALLY" || k == "RAISE_OBJ") return -1;   // the value on top goes
  if (k == "RAISE_FROM") return -2;      // the exception and its cause go
  if (k == "DUP_TWO") return 2;
  if (k == "BUILD_LIST" || k == "BUILD_TUPLE" || k == "BUILD_SET") return 1 - (int)op.arg;   // the items go, the container comes
  if (k == "BUILD_SLICE") return 1 - (int)op.arg;                        // the start, stop (and step) go, the slice comes
  if (k == "STORE_MAP") return -2;                                       // the value and key go; the dict stays
  if (k == "STORE_COMP") return op.extra == 1 ? -2 : -1;                 // a dict takes its key and value, a list its item
  if (k == "UNPACK_SEQUENCE") return (int)op.arg - 1;
  if (k == "LOAD_SUBSCR") return -1;
  if (k == "STORE_SUBSCR") return -3;
  if (k == "FOR_ITER") return 1;   // the fall-through; the exhausted jump is handled per successor
  if (k == "GET_ITER") return kIterSlots - 1;   // the object goes, the iterator's slots come
  if (k == "CALL") return -(int)op.arg;   // the function and its arguments go, the result comes
  if (k == "LOAD_METHOD") return 1;        // the object becomes the method, and stays as the self above it
  if (k == "LOAD_SUPER_METHOD") return -1; // the class and self go, the method takes the super's slot and the self stays
  if (k == "CALL_METHOD") return -(int)op.arg - 1;   // the method, the self and the arguments go, the result comes
  if (k == "MAKE_CLOSURE") return 1 - (int)op.extra;   // the captured cells go, the closure comes
  if (k == "STORE_NAME" || k == "STORE_GLOBAL" || k == "STORE_LOCAL" || k == "STORE_DEREF" || k == "POP_TOP" ||
      k == "BINARY" || k == "JUMP_IF_FALSE" || k == "JUMP_IF_TRUE" || k == "JUMP_IF_TRUE_OR_POP" ||
      k == "JUMP_IF_FALSE_OR_POP" || k == "RETURN")
    return -1;   // for the or-pop jumps this is the fall-through; the jump itself keeps the value
  // UNARY, ROT_TWO, JUMP, LOAD_ATTR (the object becomes the attribute), SETUP, POP_EXCEPT_JUMP, RAISE_LAST: no change
  return 0;
}

// An open block as the walk records it (see unit): 0 for an except, 1 for a finally, 2 for a with block and 3 for a for loop. A
// with block's value also holds the stack slot of its exit method (the slot below its context manager, as SETUP_WITH leaves
// it), and a for loop's holds the base slot of its iterator. A finally block's value holds the offset of its SETUP, which
// names the block (its handler is the SETUP's target).
int kind_of(int block) { return block & 3; }
int exit_slot_of(int block) { return block >> 2; }
int setup_of(int block) { return block >> 2; }

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
  // The bytes of a name or a str constant as a data item, one per distinct text (NUL-terminated). The module's qstr table
  // is what bytecode operands index.
  std::string text_sym(const std::string &s) {
    auto it = names_.find(s);
    if (it != names_.end()) return it->second;
    std::string sym = "mpy.text." + std::to_string(names_.size());
    names_[s] = sym;
    data_ << "(data \"" << sym << "\" (const (array " << s.size() + 1 << " (const char))) (string \"" << ir_escape(s)
          << "\\000\"))\n";
    return sym;
  }

  // The name of a qstr as a data item.
  std::string name_sym(size_t qidx) {
    if (qidx >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
    return text_sym(m_.qstrs[qidx]);
  }

  // The runtime's id of a str literal (mpy_str_lit numbers the literal sites densely), one per distinct text.
  size_t str_id(const std::string &s) {
    auto it = str_ids_.find(s);
    if (it != str_ids_.end()) return it->second;
    size_t id = str_ids_.size();
    str_ids_[s] = id;
    return id;
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
    // The walk also keeps the try blocks open at each instruction (kind 1 for a finally, 0 for an except): a
    // break or continue that leaves one is an UNWIND_JUMP, and a return or unwind through a finally runs its body (see unwind).
    std::map<size_t, int> depth;
    std::map<size_t, std::vector<int>> blocks_at;
    std::map<size_t, size_t> index;
    for (size_t i = 0; i < ops.size(); ++i) index[ops[i].offset] = i;
    std::vector<size_t> work{0};
    depth[0] = 0;
    blocks_at[0] = {};
    while (!work.empty()) {
      size_t at = work.back();
      work.pop_back();
      if (!index.count(at)) throw std::runtime_error("mpy: a jump lands between instructions");
      const Op &op = ops[index[at]];
      int d = depth[at];
      const std::vector<int> open = blocks_at[at];
      int after = d + effect(op);
      if (after < 0) throw std::runtime_error("mpy: stack underflow");
      // (successor, depth there, the try blocks open there). A jump-or-pop keeps its value when it jumps, so the target is at
      // depth d.
      struct Succ {
        size_t at;
        int depth;
        std::vector<int> blocks;
      };
      std::vector<Succ> succ;
      std::vector<int> popped = open;
      if (!popped.empty() && (op.kind == "POP_EXCEPT_JUMP" || op.kind == "END_FINALLY")) popped.pop_back();
      if (op.kind == "RETURN" || op.kind == "RAISE_OBJ" || op.kind == "RAISE_LAST" || op.kind == "RAISE_FROM") {
        // nothing follows (a raise never returns)
      } else if (op.kind == "SETUP" || op.kind == "SETUP_WITH") {
        // the handler is entered with the exception on top: the depth there is one more than at the try. A with statement's
        // stack at its handler is the exit method, the context manager and the exception, so it is two more than before.
        // A with block records its exit method's slot, which is the depth before it less one (SETUP_WITH's lowering).
        // 1 for SETUP_FINALLY (named by its offset, see setup_of), 0 for SETUP_EXCEPT
        int kind = op.kind == "SETUP_WITH" ? (2 | ((d - 1) << 2)) : (op.extra == 1 ? (1 | ((int)op.offset << 2)) : op.extra);
        std::vector<int> inner = open;
        inner.push_back(kind);
        succ.push_back({op.next, after, inner});
        succ.push_back({(size_t)op.arg, op.kind == "SETUP_WITH" ? d + 2 : d + 1, inner});
      } else if (op.kind == "POP_EXCEPT_JUMP") {
        succ.push_back({(size_t)op.arg, after, popped});
      } else if (op.kind == "UNWIND_JUMP") {
        // Pops the blocks it leaves (extra & 0x7f of them), then, when bit 0x80 is set, the for loop it breaks out of. The stack
        // at the target is the one the loop body had at its start: a with block's exit method and context manager are dropped with
        // it (WITH_CLEANUP removes them), so the target is the lowest such slot; a break also drops the iterator.
        size_t n = (size_t)(op.extra & 0x7f);
        if (n > open.size()) throw std::runtime_error("mpy: an unwind leaves more blocks than are open");
        std::vector<int> left(open.begin(), open.end() - (long)n);
        int target_depth = d;
        for (size_t i = open.size() - n; i < open.size(); ++i) {
          if (kind_of(open[i]) == 2 && exit_slot_of(open[i]) < target_depth) target_depth = exit_slot_of(open[i]);
        }
        if (op.extra & 0x80) {
          // the loop's entry is the next block out: it goes, and the target is the loop's base
          if (left.empty() || kind_of(left.back()) != 3) throw std::runtime_error("mpy: internal: a break without its loop");
          target_depth = exit_slot_of(left.back());
          left.pop_back();
        }
        succ.push_back({(size_t)op.arg, target_depth, left});
      } else if (op.kind == "GET_ITER") {
        // A for loop's iterator: its kIterSlots slots start at the slot below the object. The loop is an entry (kind 3) in the
        // open blocks until it is exhausted, so a break or continue out of the body can find its base.
        std::vector<int> inner = open;
        inner.push_back(3 | ((d - 1) << 2));
        succ.push_back({op.next, after, inner});
      } else if (op.kind == "JUMP") {
        // A break with no block to leave is four POP_TOPs (the iterator) and a JUMP (mp_emit_bc_unwind_jump): the JUMP at the
        // loop's base leaves the loop, so its entry goes. Any other jump in a loop body is above the base.
        std::vector<int> leaving = open;
        if (!leaving.empty() && kind_of(leaving.back()) == 3 && d == exit_slot_of(leaving.back())) leaving.pop_back();
        succ.push_back({(size_t)op.arg, after, leaving});
      } else if (op.kind == "JUMP_IF_FALSE" || op.kind == "JUMP_IF_TRUE") {
        succ.push_back({(size_t)op.arg, after, open});
        succ.push_back({op.next, after, open});
      } else if (op.kind == "FOR_ITER") {
        // exhausted: the iterator's kIterSlots slots are dropped, so the target is that much shallower, and the loop's entry ends
        std::vector<int> done = open;
        if (done.empty() || kind_of(done.back()) != 3) throw std::runtime_error("mpy: internal: a for loop without its entry");
        done.pop_back();
        succ.push_back({(size_t)op.arg, d - kIterSlots, done});
        succ.push_back({op.next, after, open});
      } else if (op.kind == "JUMP_IF_FALSE_OR_POP" || op.kind == "JUMP_IF_TRUE_OR_POP") {
        succ.push_back({(size_t)op.arg, d, open});
        succ.push_back({op.next, after, open});
      } else if (op.kind == "END_FINALLY") {
        succ.push_back({op.next, after, popped});
      } else {
        succ.push_back({op.next, after, open});
      }
      for (const Succ &s : succ) {
        if (s.at >= code.size()) throw std::runtime_error("mpy: a jump leaves the code");
        auto it = depth.find(s.at);
        if (it == depth.end()) {
          depth[s.at] = s.depth;
          blocks_at[s.at] = s.blocks;
          work.push_back(s.at);
        } else if (it->second != s.depth || blocks_at[s.at] != s.blocks) {
          // A break out of a finally body, in a loop over a range (no iterator on the stack, so no loop-drop bit), reaches the
          // loop's end with the finally's pending value still on the stack, one deeper than the normal exit: the reference's
          // POP_TOP there pops that value and leaves the loop's counter behind. A static depth cannot hold both, so it is refused.
          if (op.kind == "UNWIND_JUMP") refused("a break out of a finally body in a loop over a range is not lowered yet");
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
    std::ostringstream stubs;   // the landing of each try block: out of line, after the body (see SETUP)
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

    // A str literal: its bytes are a data item, and mpy_str_lit returns the record (allocated on first use). Returns the value.
    std::function<std::string(const std::string &)> str_value = [&](const std::string &text) {
      std::string sym = text_sym(text), r = fresh();
      body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_str_lit\" @\"" << sym << "\" (const unsigned_long "
           << text.size() << ") (const unsigned_long " << str_id(text) << ")))\n";
      return r;
    };

    // A constant object, as mpy-cross writes it: None, a bool, an int of the small range, a str, or a tuple of those (mpy-cross
    // folds a tuple of constants into one object). A tuple is built on each run, from its items pushed on the value stack.
    std::function<std::string(const Obj &)> constant = [&](const Obj &o) -> std::string {
      std::string word;
      if (o.kind == Obj::Kind::Str) return str_value(o.text);
      if (o.kind == Obj::Kind::Tuple) {
        std::vector<std::string> vals;
        for (const Obj &item : o.items) vals.push_back(constant(item));
        for (const std::string &v : vals) body << "  (eval (call void &\"mpy_push\" " << v << "))\n";
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_build_tuple\" (const unsigned_long " << o.items.size()
             << ")))\n";
        return r;
      }
      if (o.kind == Obj::Kind::None) word = std::to_string(6ULL);
      else if (o.kind == Obj::Kind::False) word = std::to_string(14ULL);
      else if (o.kind == Obj::Kind::True) word = std::to_string(22ULL);
      else if (o.kind == Obj::Kind::Int) word = std::to_string(small_word(int_constant(o.text)));
      else refused("a constant object of this kind is not lowered yet");
      std::string r = fresh();
      body << "  (let " << r << " unsigned_long (const unsigned_long " << word << "))\n";
      return r;
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

    // An unwind (a return, or a break or continue that leaves try blocks) runs each finally block it leaves whose handler is ahead
    // of the unwind's site, as the VM does (vm.c's unwind_jump: exc_sp->handler >= ip). The block stays open, and its handler is
    // entered with a pending code in its exception slot; the handler's END_FINALLY dispatches on the code and goes on with the
    // rest of the unwind, which is the continuation of that code (in stubs). A finally whose handler is behind the site (the site
    // is in the handler) is only dropped, as the VM cancels it. The pending codes of each finally block are collected first, so
    // that its END_FINALLY can dispatch on them.
    struct Pending {
      long long code;
      std::string cont;
    };
    std::map<size_t, std::vector<Pending>> pending_at;   // by the SETUP offset of the finally block the code enters
    std::vector<std::string> rv_slots;                  // a return's value while a finally runs
    auto runs_finally = [&](int block, size_t site) {
      return kind_of(block) == 1 && site < (size_t)ops[index[(size_t)setup_of(block)]].arg;
    };
    auto pending_code = [](size_t site, long long i) { return (long long)site * 256 + i + 1; };
    auto cont_label = [](size_t site, long long i) { return "unw_" + std::to_string(site) + "_" + std::to_string(i); };
    for (const Op &op : ops) {
      if (op.kind != "RETURN" && op.kind != "UNWIND_JUMP") continue;
      auto bit = blocks_at.find(op.offset);
      if (bit == blocks_at.end()) continue;
      const std::vector<int> &open = bit->second;
      long long top = (long long)open.size() - 1;
      long long lo = op.kind == "RETURN" ? 0 : top + 1 - (long long)(op.extra & 0x7f);
      for (long long i = top; i >= lo; --i) {
        if (!runs_finally(open[(size_t)i], op.offset)) continue;
        pending_at[(size_t)setup_of(open[(size_t)i])].push_back({pending_code(op.offset, i), cont_label(op.offset, i)});
      }
    }
    // The unwind of the blocks open[lo..top] at the site (innermost first), then finish. A with block calls its __exit__ with
    // None, None, None (WITH_CLEANUP's normal path), and an except block or a finally block that is dropped is popped before the
    // exit is called, so an exception from the exit goes to the blocks that enclose the statement. A for loop's entry (kind 3)
    // has no block to drop, so it is skipped.
    std::function<void(std::ostringstream &, long long, long long, size_t, const std::function<void(std::ostringstream &)> &)>
        unwind;
    unwind = [&](std::ostringstream &out, long long top, long long lo, size_t site,
                 const std::function<void(std::ostringstream &)> &finish) {
      const std::vector<int> open = blocks_at[site];
      for (long long i = top; i >= lo; --i) {
        int b = open[(size_t)i];
        if (kind_of(b) == 3) continue;
        if (runs_finally(b, site)) {
          size_t setup = (size_t)setup_of(b);
          size_t handler = (size_t)ops[index[setup]].arg;
          int exc_slot = depth[setup];
          out << "  (eval (call void &\"mpy_block_land\"))\n";
          out << "  (store unsigned_long " << slot("stk", exc_slot) << " (const unsigned_long "
              << small_word(pending_code(site, i)) << "))\n";
          out << "  (goto " << lbl(handler) << ")\n";
          stubs << "  (label \"" << cont_label(site, i) << "\")\n";
          unwind(stubs, i - 1, lo, site, finish);
          return;
        }
        out << "  (eval (call void &\"mpy_block_pop\"))\n";
        if (kind_of(b) == 2) {
          std::string ex = fresh(), r = fresh();
          out << "  (let " << ex << " unsigned_long (load unsigned_long " << slot("stk", exit_slot_of(b)) << "))\n";
          out << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_with_cleanup\" " << ex
              << " (const unsigned_long 6)))\n";
        }
      }
      finish(out);
    };

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
      } else if (k == "LOAD_STR" || k == "LOAD_OBJ") {
        // A str literal, or a constant object (see str_value and constant above).
        std::string value;
        if (k == "LOAD_STR") {
          if ((size_t)op.arg >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
          value = str_value(m_.qstrs[(size_t)op.arg]);
        } else {
          if ((size_t)op.arg >= m_.objs.size()) throw std::runtime_error("mpy: constant index out of range");
          value = constant(m_.objs[(size_t)op.arg]);
        }
        push(d, value);
      } else if (k == "LOAD_NAME" || k == "LOAD_GLOBAL") {
        std::string sym = name_sym((size_t)op.arg);
        size_t len = m_.qstrs[(size_t)op.arg].size();
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\""
             << (k == "LOAD_NAME" ? "mpy_load_name" : "mpy_load_global") << "\" @\"" << sym
             << "\" (const unsigned_long " << len << ")))\n";
        push(d, r);
      } else if (k == "STORE_NAME" || k == "STORE_GLOBAL") {
        std::string sym = name_sym((size_t)op.arg);
        size_t len = m_.qstrs[(size_t)op.arg].size();
        std::string v = pop(d);
        body << "  (eval (call void &\"" << (k == "STORE_NAME" ? "mpy_store_name" : "mpy_store_global") << "\" @\"" << sym
             << "\" (const unsigned_long " << len << ") " << v << "))\n";
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
      } else if (k == "DUP_TWO") {
        std::string a = load(d - 2), b = load(d - 1);
        push(d, a);
        push(d + 1, b);
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
      } else if (k == "DELETE_DEREF") {
        // del of a cell: the cell's value is 0 (unbound), so a read of it is a NameError, as mpy_cell_get gives it
        std::string cell = fresh();
        body << "  (let " << cell << " unsigned_long (load unsigned_long " << local(op.arg) << "))\n";
        body << "  (eval (call void &\"mpy_cell_set\" " << cell << " (const unsigned_long 0)))\n";
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
      } else if (k == "LOAD_METHOD") {
        // obj.name: the method, and the self to pass it (0 when the attribute is not a method of the class, so the call takes
        // none). mpy_load_method fails for a value that has no such attribute. The builtin methods of the other types are
        // refused by name, since the runtime does not have them.
        if ((size_t)op.arg >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
        const std::string name = m_.qstrs[(size_t)op.arg];
        if (kBuiltinMethods.count(name)) refused("method " + name + " is not lowered yet");
        std::string obj = pop(d), sym = name_sym((size_t)op.arg), meth = fresh(), self = fresh();
        body << "  (let " << meth << " unsigned_long (call unsigned_long &\"mpy_load_method\" " << obj << " @\"" << sym
             << "\" (const unsigned_long " << name.size() << ")))\n";
        body << "  (let " << self << " unsigned_long (call unsigned_long &\"mpy_method_self\"))\n";
        push(d - 1, meth);
        push(d, self);
      } else if (k == "LOAD_SUPER_METHOD") {
        // [super, cls, self] become [method, self]: vm.c writes the method over the super global's slot and leaves the self.
        if ((size_t)op.arg >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
        std::string self = pop(d), cls = load(d - 2), sym = name_sym((size_t)op.arg), meth = fresh(), out = fresh();
        body << "  (let " << meth << " unsigned_long (call unsigned_long &\"mpy_load_super_method\" " << cls << " " << self
             << " @\"" << sym << "\" (const unsigned_long " << m_.qstrs[(size_t)op.arg].size() << ")))\n";
        body << "  (let " << out << " unsigned_long (call unsigned_long &\"mpy_method_self\"))\n";
        push(d - 3, meth);
        push(d - 2, out);
      } else if (k == "CALL_METHOD") {
        // [method, self, args...]: the self (0 for none) and the arguments go on the value stack; mpy_call_method drops a
        // null self and calls.
        int n = (int)op.arg;
        for (int i = 0; i <= n; ++i) {
          std::string v = load(d - n - 1 + i);
          body << "  (eval (call void &\"mpy_push\" " << v << "))\n";
        }
        std::string f = load(d - n - 2);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_call_method\" " << f << " (const unsigned_long " << n
             << ")))\n";
        push(d - n - 2, r);
      } else if (k == "LOAD_ATTR") {
        if ((size_t)op.arg >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
        std::string obj = pop(d), sym = name_sym((size_t)op.arg), r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_load_attr\" " << obj << " @\"" << sym
             << "\" (const unsigned_long " << m_.qstrs[(size_t)op.arg].size() << ")))\n";
        push(d - 1, r);
      } else if (k == "STORE_ATTR") {
        // the object is on top, the value below it
        if ((size_t)op.arg >= m_.qstrs.size()) throw std::runtime_error("mpy: qstr index out of range");
        std::string obj = pop(d), val = pop(d - 1), sym = name_sym((size_t)op.arg);
        body << "  (eval (call void &\"mpy_store_attr\" " << obj << " @\"" << sym << "\" (const unsigned_long "
             << m_.qstrs[(size_t)op.arg].size() << ") " << val << "))\n";
      } else if (k == "BUILD_CLASS") {
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_build_class_fn\"))\n";
        push(d, r);
      } else if (k == "SETUP" || k == "SETUP_WITH") {
        // A try block (SETUP_EXCEPT, SETUP_FINALLY, SETUP_WITH): the block is pushed, and _setjmp is called on it in this frame. It
        // returns 0 here; when a raise longjmps back, it returns 1, and the landing stub (after the body) hands the exception to
        // the handler at the target, in the slot of this depth (the slot above the context manager for a with statement).
        int exc_slot = d;
        if (k == "SETUP_WITH") {
          // __exit__ is looked up and __enter__ called before the block, so an exception from __enter__ is not this with's.
          // The exit method goes below the context manager (slot d-1 is the manager's, moved to d), and __enter__'s value on top.
          std::string ctx = load(d - 1), ex = fresh(), en = fresh();
          body << "  (let " << ex << " unsigned_long (call unsigned_long &\"mpy_with_exit\" " << ctx << "))\n";
          body << "  (let " << en << " unsigned_long (call unsigned_long &\"mpy_with_enter\" " << ctx << "))\n";
          push(d - 1, ex);
          push(d, ctx);
          push(d + 1, en);
          exc_slot = d + 1;
        }
        std::string landing = "land" + std::to_string(op.offset);
        std::string jb = fresh(), rc = fresh(), c = fresh(), e = fresh();
        body << "  (let " << jb << " unsigned_long (call unsigned_long &\"mpy_try_enter\"))\n";
        body << "  (let " << rc << " int (call int &\"_setjmp\" " << jb << "))\n";
        body << "  (let " << c << " bool (ne int " << rc << " (const int 0)))\n";
        body << "  (if " << c << " (then (goto \"" << landing << "\")) (else))\n";
        stubs << "  (label \"" << landing << "\")\n";
        stubs << "  (let " << e << " unsigned_long (call unsigned_long &\"mpy_take_exc\"))\n";
        stubs << "  (store unsigned_long " << slot("stk", exc_slot) << " " << e << ")\n";
        stubs << "  (goto " << lbl((size_t)op.arg) << ")\n";
      } else if (k == "WITH_CLEANUP") {
        // The stack is [exit method, context manager, top] (slots d-3, d-2, d-1): the top is None when the body ended, or the
        // exception that is raised. The result takes the exit method's slot, and END_FINALLY checks it.
        std::string top = load(d - 1), ex = load(d - 3), r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_with_cleanup\" " << ex << " " << top << "))\n";
        push(d - 3, r);
      } else if (k == "POP_EXCEPT_JUMP") {
        body << "  (eval (call void &\"mpy_block_pop\"))\n";
        body << "  (goto " << lbl((size_t)op.arg) << ")\n";
      } else if (k == "UNWIND_JUMP") {
        // Leaves (extra & 0x7f) blocks, running the exit of each with block; a for loop's iterator (bit 0x80) is dropped by the
        // depth, which is static here.
        auto open_it = blocks_at.find(op.offset);
        if (open_it == blocks_at.end()) throw std::runtime_error("mpy: internal: an unwind at an unknown depth");
        long long top = (long long)open_it->second.size() - 1;
        long long lo = top + 1 - (long long)(op.extra & 0x7f);
        unwind(body, top, lo, op.offset, [&](std::ostringstream &out) { out << "  (goto " << lbl((size_t)op.arg) << ")\n"; });
      } else if (k == "RAISE_FROM") {
        // [exception, cause] with the cause on top
        std::string cause = pop(d), exc = pop(d - 1);
        body << "  (eval (call void &\"mpy_raise_from\" " << exc << " " << cause << "))\n";
      } else if (k == "END_FINALLY") {
        std::string v = pop(d);
        body << "  (eval (call void &\"mpy_end_finally\" " << v << "))\n";
        // The block that ends is the innermost one. An unwind that entered it left its pending code here: the code's continuation
        // goes on with the rest of that unwind. Otherwise (None, or an exception, which mpy_end_finally raised) the code falls through.
        auto open_it = blocks_at.find(op.offset);
        if (open_it != blocks_at.end() && !open_it->second.empty() && kind_of(open_it->second.back()) == 1) {
          auto pit = pending_at.find((size_t)setup_of(open_it->second.back()));
          if (pit != pending_at.end()) {
            for (const Pending &p : pit->second) {
              std::string c = fresh();
              body << "  (let " << c << " bool (eq unsigned_long " << v << " (const unsigned_long " << small_word(p.code)
                   << ")))\n";
              body << "  (if " << c << " (then (goto \"" << p.cont << "\")) (else))\n";
            }
          }
        }
      } else if (k == "RAISE_OBJ") {
        std::string v = pop(d);
        body << "  (eval (call void &\"mpy_raise_obj\" " << v << "))\n";
      } else if (k == "RAISE_LAST") {
        body << "  (eval (call void &\"mpy_reraise\"))\n";
      } else if (k == "DELETE_LOCAL") {
        body << "  (store unsigned_long " << local(op.arg) << " (const unsigned_long 0))\n";   // 0 is unbound
      } else if (k == "DELETE_NAME") {
        std::string sym = name_sym((size_t)op.arg);
        body << "  (eval (call void &\"mpy_delete_name\" @\"" << sym << "\" (const unsigned_long "
             << m_.qstrs[(size_t)op.arg].size() << ")))\n";
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
      } else if (k == "BUILD_LIST" || k == "BUILD_TUPLE" || k == "BUILD_SET") {
        int n = (int)op.arg;
        for (int i = 0; i < n; ++i) {
          std::string v = load(d - n + i);
          body << "  (eval (call void &\"mpy_push\" " << v << "))\n";
        }
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\""
             << (k == "BUILD_LIST" ? "mpy_build_list" : (k == "BUILD_SET" ? "mpy_build_set" : "mpy_build_tuple"))
             << "\" (const unsigned_long " << n << ")))\n";
        push(d - n, r);
      } else if (k == "LOAD_SUBSCR") {
        std::string idx = pop(d), obj = pop(d - 1);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_getitem\" " << obj << " " << idx << "))\n";
        push(d - 2, r);
      } else if (k == "STORE_SUBSCR") {
        // the index is on top, then the container, then the value
        std::string idx = pop(d), base = pop(d - 1), val = pop(d - 2);
        body << "  (eval (call void &\"mpy_setitem\" " << base << " " << idx << " " << val << "))\n";
      } else if (k == "LOAD_NULL") {
        push(d, "(const unsigned_long 0)");   // MP_OBJ_NULL: a del's value
      } else if (k == "BUILD_MAP") {
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_build_map\" (const unsigned_long " << op.arg
             << ")))\n";
        push(d, r);
      } else if (k == "STORE_MAP") {
        // [dict, value, key]: the pair is stored, and the dict stays below it
        std::string key = pop(d), val = pop(d - 1), dict = load(d - 3);
        body << "  (eval (call void &\"mpy_dict_store\" " << dict << " " << key << " " << val << "))\n";
      } else if (k == "BUILD_SLICE") {
        // [start, stop] or [start, stop, step]; a missing step is None
        int n = (int)op.arg;
        std::string start, stop, step;
        if (n == 2) {
          stop = load(d - 1);
          start = load(d - 2);
          step = "(const unsigned_long 6)";
        } else {
          step = load(d - 1);
          stop = load(d - 2);
          start = load(d - 3);
        }
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_make_slice\" " << start << " " << stop << " "
             << step << "))\n";
        push(d - n, r);
      } else if (k == "STORE_COMP") {
        // The collection is op.arg slots below the top, as vm.c's sp[-(unum >> 2)] (the top is the value, or the key). A list
        // takes the value; a dict takes the key on top and the value below it.
        int top = d - 1;
        if (op.extra == 0) {
          std::string v = load(top), coll = load(top - (int)op.arg);
          body << "  (eval (call void &\"mpy_list_append\" " << coll << " " << v << "))\n";
        } else if (op.extra == 2) {
          std::string v = load(top), coll = load(top - (int)op.arg);
          body << "  (eval (call void &\"mpy_set_store\" " << coll << " " << v << "))\n";
        } else {
          std::string key = load(top), v = load(top - 1), coll = load(top - (int)op.arg);
          body << "  (eval (call void &\"mpy_dict_store\" " << coll << " " << key << " " << v << "))\n";
        }
      } else if (k == "UNPACK_SEQUENCE") {
        int n = (int)op.arg;
        std::string seq = load(d - 1);   // read first: the item slots overlap it
        for (int i = 0; i < n; ++i) {
          std::string r = fresh();
          body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_unpack_get\" " << seq
               << " (const unsigned_long " << n << ") (const unsigned_long " << i << ")))\n";
          push(d - 1 + i, r);
        }
      } else if (k == "GET_ITER") {
        std::string obj = pop(d);
        std::string r = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_get_iter\" " << obj << "))\n";
        push(d - 1, r);
      } else if (k == "FOR_ITER") {
        std::string it = load(d - kIterSlots);
        std::string r = fresh(), c = fresh();
        body << "  (let " << r << " unsigned_long (call unsigned_long &\"mpy_iter_next\" " << it << "))\n";
        body << "  (let " << c << " bool (eq unsigned_long " << r << " (const unsigned_long 0)))\n";
        body << "  (if " << c << " (then (goto " << lbl((size_t)op.arg) << ")) (else))\n";
        push(d, r);
            } else if (k == "JUMP") {
        body << "  (goto " << lbl((size_t)op.arg) << ")\n";
      } else if (k == "RETURN") {
        // A return leaves every block it is in (MicroPython's unwind_return): a with block calls its __exit__, an except block is
        // dropped, and a finally block whose handler is ahead runs its body (see unwind). The value is kept in a slot for the
        // continuations, since a finally body reuses the stack slots from its own depth up.
        std::string v = pop(d);
        auto open_it = blocks_at.find(op.offset);
        std::vector<int> open = open_it == blocks_at.end() ? std::vector<int>{} : open_it->second;
        bool runs = false;
        for (int b : open) runs = runs || (kind_of(b) == 1 && runs_finally(b, op.offset));
        long long top = (long long)open.size() - 1;
        if (!runs) {
          unwind(body, top, 0, op.offset, [&](std::ostringstream &out) {
            if (is_fn) out << "  (store unsigned_long %0 " << v << ")\n";
            out << "  (return)\n";
          });
        } else {
          std::string rv = "rv." + std::to_string(op.offset);
          rv_slots.push_back(rv);
          body << "  (store unsigned_long $\"" << rv << "\" " << v << ")\n";
          unwind(body, top, 0, op.offset, [&](std::ostringstream &out) {
            std::string t = fresh();
            out << "  (let " << t << " unsigned_long (load unsigned_long $\"" << rv << "\"))\n";
            if (is_fn) out << "  (store unsigned_long %0 " << t << ")\n";
            out << "  (return)\n";
          });
        }
      } else {
        throw std::runtime_error("mpy: internal: kind not handled: " + k);
      }
    }
    body << stubs.str();

    std::ostringstream out;
    out << "(function \"" << fname << "\" (ret void) "
        << (is_fn ? "(params (param %0 \"ret\" (ptr unsigned_long)) (param %1 \"args\" (ptr unsigned_long)) "
                    "(param %2 \"nargs\" unsigned_long))"
                  : "(params)")
        << "\n";
    for (int d = 0; d <= max_depth; ++d) out << "  (slot \"stk." << d << "\" unsigned_long 8 8)\n";
    for (unsigned i = 0; i < pre.n_state; ++i) out << "  (slot \"loc." << i << "\" unsigned_long 8 8)\n";
    for (const std::string &s : rv_slots) out << "  (slot \"" << s << "\" unsigned_long 8 8)\n";
    out << body.str() << ")\n";
    return out.str();
  }

  const Module &m_;
  std::ostringstream data_;
  std::map<std::string, std::string> names_;
  std::map<std::string, size_t> str_ids_;   // the id of each str literal's text (mpy_str_lit)
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
