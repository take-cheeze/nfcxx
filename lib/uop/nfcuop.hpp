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
// PatternMatcher, graph_rewrite and the symbolic simplifier. Stage 3: every node has a shape; reshape,
// permute, expand and reductions; evaluate_array. The numpy-like Tensor API is nfcuop_np.hpp. Lowering to
// loops, C rendering and the nfcpoly bindings come in later stages. See docs/notes/uop.md.
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

#include "nfcuop_sym_expr.hpp"

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
  Acos, Acosh, Asin, Asinh, Atan, Atanh, Cosh, Sinh, Tan,  // unary, float only: libm's functions in double, rounded to the dtype
  Expm1, Log1p, Log10,                                 // unary, float only (libm)
  Round,                                               // unary, float only: round half to even (nearbyint in the default mode)
  Add, Sub, Mul, IDiv, FDiv, Mod, Max,                 // binary, both sources and the result of one dtype
  Atan2,                                               // binary, float only: atan2(src0, src1) (y, x)
  Shl, Shr,                                            // binary, integers only: src0 shifted by src1; Shr is arithmetic (see eval_op)
  CmpLt, CmpNe,                                        // binary, result Bool
  And, Or, Xor,                                        // binary, ints and Bool
  Where,                                               // (Bool, a, b) -> a or b
  Cast,                                                // one source, the node's dtype is the target
  Reshape, Permute, Expand,                            // movement ops (stage 3): the node's shape is the result's
  ReduceSum, ReduceMax,                                // reductions over `arg` axes; the reduced axes stay, with size 1
  Shrink, Pad, Flip,                                   // static slicing (arg = starts ++ ends), zero padding (arg = before ++ after), reversal over arg axes
  Count_
};
const char* name(Op op);
int arity(Op op);  // number of sources (0 for leaves)
bool is_alu(Op op);
bool is_commutative(Op op);
bool is_movement(Op op);  // Reshape, Permute, Expand, Shrink, Pad, Flip
bool is_reduce(Op op);    // ReduceSum, ReduceMax

using Shape = std::vector<int64_t>;  // empty: a scalar; every dimension is at least 1
int64_t numel(const Shape& s);
std::string to_string(const Shape& s);  // "[2,3]"
// Python's slice(start, stop, step).indices(dim) with the count of elements; has_* false means omitted. step != 0.
struct SliceIdx {
  int64_t start, step, count;  // elements start, start+step, ... (count of them; may be 0)
};
SliceIdx slice_indices(int64_t dim, bool has_start, int64_t start, bool has_stop, int64_t stop, int64_t step);

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

// Symbolic dimensions (stage 7, docs/notes/uop.md). A Symbol is tinygrad's Variable: the name of a size that is only known at run
// time, and the largest size it takes. A Graph interns its symbols, so a name is one pointer and the identity of a dimension is a
// pointer comparison. The size of a node is still its `shape` (the size in the graph); the symbols say which dimensions move with
// which size, so the C renderer needs no representative size to find them.
struct Symbol {
  std::string name;  // the name the feeds use
  int64_t bound;     // the largest size, or 0 for none
};

// A polynomial in symbols (stage 7): onnxsim's SymExpr, whose monomials name the symbols of the graph (Graph::symbol). `N` is the
// symbol itself, `2*N - 1` a polynomial, `7` an integer (a polynomial with no symbol).
using Poly = onnxsim::SymExpr;
// The dimensions given to a builder, one polynomial per dimension (an empty Dims means all integers, where the builder takes one).
using Dims = std::vector<Poly>;

// What one dimension of a node is:
//   Int      an integer: its size is the shape's, whatever the feeds are;
//   Sym      the size of `sym`: at run time it is the symbol's size;
//   Poly     a polynomial in symbols that is neither an integer nor one symbol (`N-1`, `2*N`): at run time it is the value of `poly`
//            at the symbols' sizes, which the renderer checks to be at least 1 and within its bound (when every symbol has one);
//   Wild     a constant, or a size-1 dimension that a consumer broadcasts: its size is the consumer's;
//   Unknown  not expressible: a dynamic program cannot be written, and the C renderer falls back to integer loops.
struct SymDim {
  enum Kind : uint8_t { Int, Sym, Wild, Unknown, Poly };
  Kind kind = Int;
  const Symbol* sym = nullptr;  // Sym only
  nfcuop::Poly poly;            // Poly only (qualified: the enumerator Poly hides the alias inside SymDim)
  static SymDim of(Kind k, const Symbol* s = nullptr) {
    SymDim d;
    d.kind = k;
    d.sym = s;
    return d;
  }
  bool operator==(const SymDim& o) const {
    return kind == o.kind && sym == o.sym && (kind != Poly || poly == o.poly);
  }
  bool operator!=(const SymDim& o) const { return !(*this == o); }
};
using SymShape = std::vector<SymDim>;  // one entry per dimension of the shape

// The symbols of builder arguments: syms[k] is the symbol of dimension k, nullptr for an integer. Empty means all integers.
using Syms = std::vector<const Symbol*>;

struct UOp {
  Op op;
  DType dtype;
  std::vector<const UOp*> src;
  Scalar value;      // Const only: every element of the (possibly shaped) constant
  std::string name;  // Var only
  uint32_t id;       // creation order in its Graph; a source always has a smaller id
  Shape shape;       // of the value this node computes; the empty shape is a scalar
  SymShape sym;      // the symbolic form of `shape`: what each dimension is (stage 7)
  Shape arg;         // Permute: the permutation; reductions and Flip: the axes, ascending; Shrink: starts then ends; Pad: before then after
  bool is_const() const { return op == Op::Const; }
};

// The symbol of each dimension of `u` (nullptr for an integer, and for a Wild, Unknown or Poly dimension): the Syms that rebuild its shape.
Syms symbols_of(const UOp* u);
// The polynomial of each dimension of `u`: its symbol, its polynomial, or its size as an integer (Wild and Unknown dimensions too).
// The Dims that rebuild its shape with the explicit builders.
Dims dims_of(const UOp* u);

// Owns every node. Nodes are immutable and live as long as the Graph; building the same node twice returns
// the same pointer, so `a == b` on UOp pointers is structural equality. A Graph is not thread safe, and
// nodes of different graphs must not be mixed.
class Graph {
 public:
  Graph();
  ~Graph();
  Graph(const Graph&) = delete;
  Graph& operator=(const Graph&) = delete;

  // A constant tensor with every element `s`; the default shape is a scalar.
  const UOp* constant(const Scalar& s, const Shape& shape = {});
  const UOp* iconst(DType d, int64_t v, const Shape& shape = {}) { return constant(Scalar::from_int(d, v), shape); }
  const UOp* fconst(DType d, double v, const Shape& shape = {}) { return constant(Scalar::from_double(d, v), shape); }
  // A named input; evaluate() binds it to a value of this dtype and shape.
  const UOp* var(const std::string& name, DType d, const Shape& shape = {});
  // A symbol: the same name is the same Symbol. `bound` is the largest size it takes (0: none, the default); asking for the name
  // again with another bound throws Error.
  const Symbol* symbol(const std::string& name, int64_t bound = 0);
  // A named input whose dimension k is the symbol syms[k] (nullptr: an integer; empty: all integers). Its size in the graph is
  // `shape`, and a symbol's size must not exceed its bound.
  const UOp* var(const std::string& name, DType d, const Shape& shape, const Syms& syms);
  // The polynomial forms (stage 7, step 3). Dims has one polynomial per dimension (`Poly`: the symbol, a polynomial such as 2*N - 1, or
  // an integer); each symbol in it must be a symbol of this graph (Graph::symbol). An integer entry must be the dimension's size, and a
  // polynomial whose symbols all have bounds must not exceed its largest value at `shape`. The renderer checks the run-time sizes.
  const UOp* var_poly(const std::string& name, DType d, const Shape& shape, const Dims& dims);

  // Builds an ALU node (anything but Const, Var and Cast), inferring the dtype and checking the sources,
  // which must have the same shape (broadcasting is explicit: expand, or the Tensor API).
  const UOp* alu(Op op, std::vector<const UOp*> src);
  const UOp* cast(const UOp* x, DType to);
  // Movement and reductions (stage 3). reshape: same number of elements. permute: result dim i is source
  // dim perm[i]. expand: same rank, a dimension stays or grows from 1. reduce_*: `axes` need not be sorted;
  // the reduced axes remain with size 1 (keepdims), reshape drops them.
  // The symbolic forms (stage 7) take the symbol of each dimension of `shape` (Syms; empty: all integers). The shape-only forms
  // keep a symbol only where the operation leaves its dimension alone, and make every other symbolic dimension Unknown:
  //   reshape(x, shape, syms): the target's element count must be that of x as a polynomial (for every size of the symbols), and a
  //     symbol that both name a dimension must have the same size in both; the target keeps its symbols. reshape(x, shape): a symbolic
  //     x keeps the symbols of the leading dimensions up to the last one when their sizes are unchanged, and nothing else.
  //   expand(x, shape, syms): a dimension of x that is its symbol stays; a size-1 dimension (or a constant) grows to the symbol
  //     given, and a literal target is an integer. expand(x, shape): a size-1 dimension that grows is Wild (its size is that of its
  //     consumer, as before); a symbolic dimension is Unknown.
  //   The same explicit forms take polynomials (reshape_poly, expand_poly, shrink_poly, var_poly: `Dims`, see below); a Syms argument
  //   is the same as the Dims of its symbols.
  const UOp* reshape(const UOp* x, const Shape& shape);
  const UOp* reshape(const UOp* x, const Shape& shape, const Syms& syms);
  // The explicit form with polynomials: the element count of the target must be that of x as a polynomial (for every size of the
  // symbols), so `[N,4]` reshapes to `[2*N,2]`, and `[N,4]` to `[4,3]` is an Error.
  const UOp* reshape_poly(const UOp* x, const Shape& shape, const Dims& dims);
  const UOp* permute(const UOp* x, const Shape& perm);
  const UOp* expand(const UOp* x, const Shape& shape);
  const UOp* expand(const UOp* x, const Shape& shape, const Syms& syms);
  const UOp* expand_poly(const UOp* x, const Shape& shape, const Dims& dims);
  const UOp* reduce_sum(const UOp* x, const Shape& axes);
  const UOp* reduce_max(const UOp* x, const Shape& axes);
  // shrink: keep [starts[i], ends[i]) of each dimension (non-empty). pad: add before[i] and after[i] zeros (false for
  // bool) to each dimension. flip: reverse the given axes.
  // With `end_syms`, the end of dimension k is its symbol (its polynomial is the symbol): the whole dimension (start 0) keeps the
  // symbol, and any other end of a symbolic dimension is the polynomial minus the start (x[1:N] of [N] is N-1). A literal end of a
  // symbolic dimension is an integer of the cut's size, and the renderer checks at run time that the symbol reaches it. Without
  // end_syms, every cut is literal.
  const UOp* shrink(const UOp* x, const Shape& starts, const Shape& ends);
  const UOp* shrink(const UOp* x, const Shape& starts, const Shape& ends, const Syms& end_syms);
  // With the end of each dimension as a polynomial (`ends_poly`, one entry per dimension; empty: the literal `ends`). An integer
  // entry must equal ends[k]. A polynomial end E keeps the source's dimension when it is the whole of it (start 0, E the dimension);
  // otherwise the result is E - starts[k] (N-1 for x[1:N]), and at run time the renderer checks that E is within the source's size.
  const UOp* shrink_poly(const UOp* x, const Shape& starts, const Shape& ends, const Dims& ends_poly);
  const UOp* pad(const UOp* x, const Shape& before, const Shape& after);
  const UOp* flip(const UOp* x, const Shape& axes);
  // The node `u` with other sources (u->op, u->dtype and its symbolic dimensions are kept; Const and Var are returned as they are).
  const UOp* rebuild(const UOp* u, std::vector<const UOp*> src);

  const UOp* neg(const UOp* a) { return alu(Op::Neg, {a}); }
  const UOp* sqrt(const UOp* a) { return alu(Op::Sqrt, {a}); }
  const UOp* exp2(const UOp* a) { return alu(Op::Exp2, {a}); }
  const UOp* log2(const UOp* a) { return alu(Op::Log2, {a}); }
  const UOp* sin(const UOp* a) { return alu(Op::Sin, {a}); }
  const UOp* acos(const UOp* a) { return alu(Op::Acos, {a}); }
  const UOp* acosh(const UOp* a) { return alu(Op::Acosh, {a}); }
  const UOp* asin(const UOp* a) { return alu(Op::Asin, {a}); }
  const UOp* asinh(const UOp* a) { return alu(Op::Asinh, {a}); }
  const UOp* atan(const UOp* a) { return alu(Op::Atan, {a}); }
  const UOp* atanh(const UOp* a) { return alu(Op::Atanh, {a}); }
  const UOp* cosh(const UOp* a) { return alu(Op::Cosh, {a}); }
  const UOp* sinh(const UOp* a) { return alu(Op::Sinh, {a}); }
  const UOp* tan(const UOp* a) { return alu(Op::Tan, {a}); }
  const UOp* expm1(const UOp* a) { return alu(Op::Expm1, {a}); }
  const UOp* log1p(const UOp* a) { return alu(Op::Log1p, {a}); }
  const UOp* log10(const UOp* a) { return alu(Op::Log10, {a}); }
  const UOp* round(const UOp* a) { return alu(Op::Round, {a}); }
  const UOp* atan2(const UOp* y, const UOp* x) { return alu(Op::Atan2, {y, x}); }
  const UOp* shl(const UOp* a, const UOp* b) { return alu(Op::Shl, {a, b}); }
  const UOp* shr(const UOp* a, const UOp* b) { return alu(Op::Shr, {a, b}); }
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
  const UOp* intern(Op op, DType dt, std::vector<const UOp*> src, const Scalar& value, const std::string& name,
                    const Shape& shape, const Shape& arg, const SymShape& sym);
  const UOp* reduce(Op op, const UOp* x, Shape axes);
  std::deque<UOp> nodes_;                                        // stable addresses
  std::unordered_map<size_t, std::vector<const UOp*>> table_;    // hash -> nodes
  std::deque<Symbol> symbols_;                                   // stable addresses
  std::map<std::string, const Symbol*> symtab_;                  // name -> symbol
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
// The reference interpreter for scalar graphs: the value of `root` (whose shape must be empty) with every
// Var bound by name (a binding must have the Var's dtype). Integers wrap, IDiv and Mod truncate toward zero
// like C, a Float32 node is computed in double and rounded to float, Max returns the non-NaN operand (the second when they
// compare equal, so max(0.0, -0.0) is -0.0).
Scalar evaluate(const UOp* root, const std::map<std::string, Scalar>& vars = {});

// A dense row-major tensor value (stage 3), one Scalar per element.
struct Array {
  DType dtype = DType::Float32;
  Shape shape;
  std::vector<Scalar> data;  // numel(shape) elements
  Array() {}
  Array(DType d, Shape s, std::vector<Scalar> v) : dtype(d), shape(std::move(s)), data(std::move(v)) {}
  static Array full(DType d, const Shape& shape, const Scalar& v);
  // From doubles (converted to `d` as Scalar::from_double does); data.size() must equal numel(shape).
  static Array from_doubles(DType d, const Shape& shape, const std::vector<double>& v);
};
// The reference interpreter for tensor graphs. Elementwise ops apply eval_op per element; ReduceSum
// accumulates in row-major order of the source starting from its first element, ReduceMax likewise.
Array evaluate_array(const UOp* root, const std::map<std::string, Array>& vars = {});

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
