// nfcuop: a tinygrad-style UOp IR. One small op set, nodes that are immutable and hash-consed (equal
// structure is the same pointer), and rewriting by pattern matching.
//
//   nfcuop::Graph g;
//   auto x = g.var("x", nfcuop::DType::Int32);
//   auto e = g.add(g.mul(x, g.iconst(nfcuop::DType::Int32, 1)), g.iconst(nfcuop::DType::Int32, 0));
//   auto s = nfcuop::graph_rewrite(g, nfcuop::symbolic(), e);   // s == x, the very same pointer
//   nfcuop::Scalar r = nfcuop::evaluate(s, {{"x", nfcuop::Scalar::from_int(nfcuop::DType::Int32, 5)}});
//
// Stage 1 (scalar core): Graph, interning, a reference interpreter, a text dump. Stage 2: Pat,
// PatternMatcher, graph_rewrite and the symbolic simplifier. Tensors, lowering to loops, C rendering and
// the nfcpoly bindings come in later stages. See docs/notes/uop.md.
#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace nfcuop {

// Every error the library reports: ill-typed nodes, unbound variables, division by zero when evaluating,
// a rewrite that does not terminate.
struct Error : std::runtime_error {
  using std::runtime_error::runtime_error;
};

enum class DType : uint8_t { Bool, Int32, Int64, Float32, Float64 };
const char* name(DType d);
bool is_float(DType d);
bool is_int(DType d);  // Int32 or Int64 (Bool is neither)

enum class Op : uint8_t {
  Const, Var,                                          // leaves
  Neg, Sqrt, Exp2, Log2, Sin,                          // unary; all but Neg are float only
  Add, Sub, Mul, IDiv, FDiv, Mod, Max,                 // binary, both sources and the result of one dtype
  CmpLt, CmpNe,                                        // binary, result Bool
  And, Or, Xor,                                        // binary, ints and Bool
  Where,                                               // (Bool, a, b) -> a or b
  Cast,                                                // one source, the node's dtype is the target
  Count_
};
const char* name(Op op);
int arity(Op op);  // number of sources (0 for leaves)
bool is_alu(Op op);
bool is_commutative(Op op);

// One value of one dtype. Bool and the ints keep the value in `i` (sign extended, already wrapped to the
// width of the dtype); the floats keep it in `f` (a Float32 is always a value representable as float).
struct Scalar {
  DType dtype = DType::Int32;
  int64_t i = 0;
  double f = 0;
  static Scalar from_int(DType d, int64_t v);     // wraps for the ints, != 0 for Bool, converts for the floats
  static Scalar from_double(DType d, double v);   // rounds for Float32, truncates (saturating, NaN -> 0) for the ints
  bool operator==(const Scalar& o) const;         // same dtype and same value (bitwise for floats)
  bool operator!=(const Scalar& o) const { return !(*this == o); }
  double as_double() const { return is_float(dtype) ? f : static_cast<double>(i); }
};
std::string to_string(const Scalar& s);

struct UOp {
  Op op;
  DType dtype;
  std::vector<const UOp*> src;
  Scalar value;      // Const only
  std::string name;  // Var only
  uint32_t id;       // creation order in its Graph; a source always has a smaller id
  bool is_const() const { return op == Op::Const; }
};

// Owns every node. Nodes are immutable and live as long as the Graph; building the same node twice returns
// the same pointer, so `a == b` on UOp pointers is structural equality. A Graph is not thread safe, and
// nodes of different graphs must not be mixed.
class Graph {
 public:
  Graph();
  ~Graph();
  Graph(const Graph&) = delete;
  Graph& operator=(const Graph&) = delete;

  const UOp* constant(const Scalar& s);
  const UOp* iconst(DType d, int64_t v) { return constant(Scalar::from_int(d, v)); }
  const UOp* fconst(DType d, double v) { return constant(Scalar::from_double(d, v)); }
  const UOp* var(const std::string& name, DType d);

  // Builds an ALU node (anything but Const, Var and Cast), inferring the dtype and checking the sources.
  const UOp* alu(Op op, std::vector<const UOp*> src);
  const UOp* cast(const UOp* x, DType to);
  // The node `u` with other sources (u->op and u->dtype are kept; Const and Var are returned as they are).
  const UOp* rebuild(const UOp* u, std::vector<const UOp*> src);

  const UOp* neg(const UOp* a) { return alu(Op::Neg, {a}); }
  const UOp* sqrt(const UOp* a) { return alu(Op::Sqrt, {a}); }
  const UOp* exp2(const UOp* a) { return alu(Op::Exp2, {a}); }
  const UOp* log2(const UOp* a) { return alu(Op::Log2, {a}); }
  const UOp* sin(const UOp* a) { return alu(Op::Sin, {a}); }
  const UOp* add(const UOp* a, const UOp* b) { return alu(Op::Add, {a, b}); }
  const UOp* sub(const UOp* a, const UOp* b) { return alu(Op::Sub, {a, b}); }
  const UOp* mul(const UOp* a, const UOp* b) { return alu(Op::Mul, {a, b}); }
  const UOp* idiv(const UOp* a, const UOp* b) { return alu(Op::IDiv, {a, b}); }
  const UOp* fdiv(const UOp* a, const UOp* b) { return alu(Op::FDiv, {a, b}); }
  const UOp* mod(const UOp* a, const UOp* b) { return alu(Op::Mod, {a, b}); }
  const UOp* max(const UOp* a, const UOp* b) { return alu(Op::Max, {a, b}); }
  const UOp* cmplt(const UOp* a, const UOp* b) { return alu(Op::CmpLt, {a, b}); }
  const UOp* cmpne(const UOp* a, const UOp* b) { return alu(Op::CmpNe, {a, b}); }
  const UOp* band(const UOp* a, const UOp* b) { return alu(Op::And, {a, b}); }
  const UOp* bor(const UOp* a, const UOp* b) { return alu(Op::Or, {a, b}); }
  const UOp* bxor(const UOp* a, const UOp* b) { return alu(Op::Xor, {a, b}); }
  const UOp* where(const UOp* c, const UOp* a, const UOp* b) { return alu(Op::Where, {c, a, b}); }

  size_t size() const { return nodes_.size(); }

 private:
  const UOp* intern(Op op, DType dt, std::vector<const UOp*> src, const Scalar& value, const std::string& name);
  std::deque<UOp> nodes_;                                        // stable addresses
  std::unordered_map<size_t, std::vector<const UOp*>> table_;    // hash -> nodes
};

// The nodes `root` depends on, sources before users, `root` last; each once.
std::vector<const UOp*> toposort(const UOp* root);
// One line per node in toposort order, numbered from 0: `  3 ADD    int32   (1, 2)` and, for a leaf, its
// value or name. Independent of ids and addresses, so it can be compared with a golden text.
std::string dump(const UOp* root);

// What an ALU node computes on constant sources: the single definition used by evaluate() and by the
// constant folding of symbolic(). `op` is an ALU op or Cast, `out` the dtype of the result. Throws Error on
// an integer division by zero.
Scalar eval_op(Op op, DType out, const std::vector<Scalar>& args);
// The reference interpreter: the value of `root` with every Var bound by name (a binding must have the
// Var's dtype). Integers wrap, IDiv and Mod truncate toward zero like C, a Float32 node is computed in
// double and rounded to float, Max returns the non-NaN operand.
Scalar evaluate(const UOp* root, const std::map<std::string, Scalar>& vars = {});

// ---- stage 2: patterns and rewriting ----

// What a pattern bound: each name given to a sub-pattern -> the node it matched.
class Match {
 public:
  bool has(const std::string& name) const { return b_.count(name) != 0; }
  const UOp* operator[](const std::string& name) const;  // throws Error if the name is not bound
  std::map<std::string, const UOp*> b_;
};

// A pattern for a node. Building blocks: any(), cvar(), cval(), op(). A name captures the matched node in
// the Match; the same name used twice requires the same node (a pointer comparison, thanks to interning).
// For a commutative op the two sources are tried in both orders unless ordered() is called.
class Pat {
 public:
  static Pat any(const std::string& name = "");   // any node
  static Pat cvar(const std::string& name = "");  // any Const
  static Pat cval(double v);                      // a Const equal to v, of any dtype
  static Pat op(Op op, const std::string& name = "");                                          // op, any sources
  static Pat op(Op op, std::vector<Pat> src, const std::string& name = "");                    // op, these sources
  Pat& named(const std::string& name) { name_ = name; return *this; }
  Pat& with_dtype(DType d) { dtype_ = d; has_dtype_ = true; return *this; }
  Pat& ordered() { ordered_ = true; return *this; }
  bool matches(const UOp* u, Match& m) const;     // m keeps the bindings made so far; unchanged on failure

 private:
  enum Kind { Any, Cvar, Cval, OpNode } kind_ = Any;
  Op op_ = Op::Const;
  double cval_ = 0;
  std::vector<Pat> src_;
  bool any_src_ = true;
  std::string name_;
  DType dtype_ = DType::Int32;
  bool has_dtype_ = false;
  bool ordered_ = false;
};

// A rule's function returns the replacement node, or nullptr when it does not apply after all.
using RuleFn = std::function<const UOp*(Graph&, const Match&)>;

class PatternMatcher {
 public:
  PatternMatcher& add(const Pat& pat, RuleFn fn, const std::string& label = "");
  PatternMatcher& extend(const PatternMatcher& other);  // other's rules go after these
  // The first rule (in order) whose pattern matches `u` and whose function returns a node other than `u`.
  const UOp* apply(Graph& g, const UOp* u) const;
  size_t size() const { return rules_.size(); }

 private:
  struct Rule {
    Pat pat;
    RuleFn fn;
    std::string label;
  };
  std::vector<Rule> rules_;
};

// Rewrites bottom-up to a fixed point: a node's sources are rewritten first, then the rules are applied to
// the rebuilt node, and a replacement is itself rewritten. Throws Error after `max_steps` rule applications,
// or when replacements nest more than 2000 deep (rules that undo each other). Recurses along the depth of
// the graph, so a chain of some 10^4 nodes needs a bigger stack.
const UOp* graph_rewrite(Graph& g, const PatternMatcher& pm, const UOp* root, size_t max_steps = 1000000);

// Exact simplifications: constant folding, constants moved to the right of commutative ops, identities
// (x+0, x*1, x-x, x&x, Where with a constant or equal arms, Neg(Neg x), a Cast to the same dtype) and
// reassociation of integer constants ((x+1)+2 -> x+3). Integer results are always bit-identical to the
// unsimplified graph. Floats are rewritten only by the identities that hold for every value except the sign
// of a zero (x+0 -> x, x-0 -> x, x*1 -> x, x/1 -> x); x*0 -> 0 and x-x -> 0 are applied to ints only.
const PatternMatcher& symbolic();

}  // namespace nfcuop
