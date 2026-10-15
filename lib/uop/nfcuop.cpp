// nfcuop core: dtypes, scalars, the interning Graph, the reference interpreter. See nfcuop.hpp.
#include "nfcuop.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <unordered_set>

namespace nfcuop {

const char* name(DType d) {
  switch (d) {
    case DType::Bool: return "bool";
    case DType::Int32: return "int32";
    case DType::Int64: return "int64";
    case DType::Float32: return "float32";
    case DType::Float64: return "float64";
  }
  return "?";
}
bool is_float(DType d) { return d == DType::Float32 || d == DType::Float64; }
bool is_int(DType d) { return d == DType::Int32 || d == DType::Int64; }

static const char* const kOpNames[] = {"CONST", "VAR", "NEG", "SQRT", "EXP2", "LOG2", "SIN", "ACOS", "ACOSH", "ASIN",
                                       "ASINH", "ATAN", "ATANH", "COSH", "SINH", "TAN", "EXPM1", "LOG1P", "LOG10", "ROUND",
                                       "ADD", "SUB", "MUL",   "IDIV", "FDIV", "MOD", "MAX", "ATAN2", "SHL", "SHR", "CMPLT", "CMPNE", "AND", "OR",
                                       "XOR",   "WHERE", "CAST",  "RESHAPE", "PERMUTE", "EXPAND", "REDUCE_SUM", "REDUCE_MAX", "SHRINK", "PAD", "FLIP"};
static_assert(sizeof(kOpNames) / sizeof(kOpNames[0]) == static_cast<size_t>(Op::Count_), "op name table");
const char* name(Op op) { return kOpNames[static_cast<int>(op)]; }

int arity(Op op) {
  switch (op) {
    case Op::Const: case Op::Var: return 0;
    case Op::Neg: case Op::Sqrt: case Op::Exp2: case Op::Log2: case Op::Sin: case Op::Cast:
    case Op::Acos: case Op::Acosh: case Op::Asin: case Op::Asinh: case Op::Atan: case Op::Atanh: case Op::Cosh: case Op::Sinh:
    case Op::Tan: case Op::Expm1: case Op::Log1p: case Op::Log10: case Op::Round:
    case Op::Reshape: case Op::Permute: case Op::Expand: case Op::ReduceSum: case Op::ReduceMax:
    case Op::Shrink: case Op::Pad: case Op::Flip: return 1;
    case Op::Where: return 3;
    default: return 2;
  }
}
bool is_alu(Op op) { return op >= Op::Neg && op <= Op::Where; }
bool is_commutative(Op op) {
  switch (op) {
    case Op::Add: case Op::Mul: case Op::Max: case Op::CmpNe: case Op::And: case Op::Or: case Op::Xor: return true;
    default: return false;
  }
}

bool is_movement(Op op) {
  return op == Op::Reshape || op == Op::Permute || op == Op::Expand || op == Op::Shrink || op == Op::Pad || op == Op::Flip;
}
bool is_reduce(Op op) { return op == Op::ReduceSum || op == Op::ReduceMax; }

int64_t numel(const Shape& s) {
  int64_t n = 1;
  for (int64_t d : s) n *= d;
  return n;
}
std::string to_string(const Shape& s) {
  std::string out = "[";
  for (size_t k = 0; k < s.size(); k++) out += (k ? "," : "") + std::to_string(s[k]);
  return out + "]";
}
SliceIdx slice_indices(int64_t dim, bool has_start, int64_t start, bool has_stop, int64_t stop, int64_t step) {
  if (step == 0) throw Error("slice step cannot be 0");
  const int64_t lo = step < 0 ? -1 : 0, hi = step < 0 ? dim - 1 : dim;
  auto norm = [&](bool has, int64_t v, int64_t dflt) {
    if (!has) return dflt;
    if (v < 0) v = v + dim < lo ? lo : v + dim;
    return v > hi ? hi : v;
  };
  SliceIdx r;
  r.step = step;
  r.start = norm(has_start, start, step < 0 ? dim - 1 : 0);
  int64_t end = norm(has_stop, stop, step < 0 ? -1 : dim);
  int64_t span = step < 0 ? r.start - end : end - r.start, mag = step < 0 ? -step : step;
  r.count = span <= 0 ? 0 : (span + mag - 1) / mag;
  return r;
}

static void check_shape(const Shape& s, const char* what) {
  int64_t n = 1;
  for (int64_t d : s) {
    if (d < 1) throw Error(std::string(what) + ": every dimension must be at least 1, got " + to_string(s));
    if (n > (int64_t(1) << 40) / d) throw Error(std::string(what) + ": shape too large " + to_string(s));
    n *= d;
  }
}

// ---- Scalar ----

Scalar Scalar::from_int(DType d, int64_t v) {
  Scalar s;
  s.dtype = d;
  switch (d) {
    case DType::Bool: s.i = v != 0; break;
    case DType::Int32: s.i = static_cast<int32_t>(static_cast<uint32_t>(static_cast<uint64_t>(v))); break;
    case DType::Int64: s.i = v; break;
    case DType::Float32: s.f = static_cast<float>(v); break;
    case DType::Float64: s.f = static_cast<double>(v); break;
  }
  return s;
}

Scalar Scalar::from_double(DType d, double v) {
  Scalar s;
  s.dtype = d;
  if (d == DType::Float32) { s.f = static_cast<float>(v); return s; }
  if (d == DType::Float64) { s.f = v; return s; }
  if (d == DType::Bool) { s.i = v != 0; return s; }
  // ints: truncate toward zero, saturate, NaN -> 0
  double lo = d == DType::Int32 ? -2147483648.0 : -9223372036854775808.0;
  double hi = d == DType::Int32 ? 2147483647.0 : 9223372036854775808.0;  // 2^63 is exact; INT64_MAX is not
  if (std::isnan(v)) s.i = 0;
  else if (v >= hi) s.i = d == DType::Int32 ? std::numeric_limits<int32_t>::max() : std::numeric_limits<int64_t>::max();
  else if (v <= lo) s.i = d == DType::Int32 ? std::numeric_limits<int32_t>::min() : std::numeric_limits<int64_t>::min();
  else s.i = static_cast<int64_t>(v);
  return s;
}

bool Scalar::operator==(const Scalar& o) const {
  if (dtype != o.dtype || i != o.i) return false;
  return std::memcmp(&f, &o.f, sizeof f) == 0;
}

std::string to_string(const Scalar& s) {
  char buf[64];
  switch (s.dtype) {
    case DType::Bool: return s.i ? "true" : "false";
    case DType::Int32: case DType::Int64: std::snprintf(buf, sizeof buf, "%lld", static_cast<long long>(s.i)); break;
    case DType::Float32: std::snprintf(buf, sizeof buf, "%.9g", s.f); break;
    case DType::Float64: std::snprintf(buf, sizeof buf, "%.17g", s.f); break;
  }
  return buf;
}

// ---- Graph ----

Graph::Graph() {}
Graph::~Graph() {}

// ---- symbolic dimensions (stage 7) ----

namespace {

SymDim unknown_dim() { return SymDim{SymDim::Unknown, nullptr}; }

// A movement or a reduction of a shape with an Unknown dimension is Unknown as a whole: its dimensions cannot be told apart.
SymShape all_unknown(const UOp* x) {
  for (const SymDim& d : x->sym)
    if (d.kind == SymDim::Unknown) return SymShape(x->sym.size(), unknown_dim());
  return SymShape();
}

// The dimension of size `size` that is the symbol `s`, checked against the bound of `s`.
SymDim named_dim(const Symbol* s, int64_t size) {
  if (s->bound != 0 && size > s->bound)
    throw Error("symbol " + s->name + " has size " + std::to_string(size) + ", above its bound " + std::to_string(s->bound));
  return SymDim{SymDim::Sym, s};
}

// The symbolic form of a shape whose dimension k is syms[k] (empty: all integers).
SymShape named_shape(const Shape& shape, const Syms& syms, const char* what) {
  if (!syms.empty() && syms.size() != shape.size())
    throw Error(std::string(what) + ": " + std::to_string(syms.size()) + " symbols for " + std::to_string(shape.size()) + " dimensions");
  SymShape out(shape.size());
  for (size_t k = 0; k < syms.size(); k++)
    if (syms[k]) out[k] = named_dim(syms[k], shape[k]);
  return out;
}

// A constant: a dimension of size 1 is an integer, any other is Wild (a consumer gives it the size it needs).
SymShape constant_sym(const Shape& shape) {
  SymShape out(shape.size());
  for (size_t k = 0; k < shape.size(); k++) out[k] = SymDim{shape[k] == 1 ? SymDim::Int : SymDim::Wild, nullptr};
  return out;
}

// An ALU node: its sources have its shape. A symbol survives when the sources agree on it (a size-1 dimension of an integer source
// does not conflict). An integer of size above 1 next to a symbol, two different symbols, or an Unknown source make it Unknown.
SymShape alu_sym(const std::vector<const UOp*>& src, const Shape& shape) {
  SymShape out(shape.size());
  for (size_t k = 0; k < shape.size(); k++) {
    const Symbol* s = nullptr;
    bool unknown = false, integer = false;
    for (const UOp* u : src) {
      const SymDim& d = u->sym[k];
      switch (d.kind) {
        case SymDim::Unknown: unknown = true; break;
        case SymDim::Wild: break;
        case SymDim::Sym: if (s && s != d.sym) unknown = true; s = d.sym; break;
        case SymDim::Int: if (u->shape[k] != 1) integer = true; break;
      }
    }
    if (unknown || (s && integer)) out[k] = unknown_dim();
    else if (s) out[k] = SymDim{SymDim::Sym, s};
    else if (integer || shape[k] == 1) out[k] = SymDim{};
    else out[k] = SymDim{SymDim::Wild, nullptr};   // only constants
  }
  return out;
}

// Expand. `syms` gives the symbol of each target dimension (empty: none). A dimension of x that is its symbol stays; a size-1
// dimension grows to the symbol given. Without symbols (`legacy`), a size-1 dimension that grows is Wild: its size is the consumer's,
// as it always was for the shape-only form, which keeps the static graphs' planning. With symbols, a literal target is an integer,
// so the broadcast stays dynamic. A symbolic x dimension that the target does not name, or a literal size for it, is Unknown: no
// dynamic program can say what it is.
SymShape expand_sym(const UOp* x, const Shape& shape, const Syms& syms, bool legacy) {
  const SymShape target = named_shape(shape, syms, "EXPAND");
  if (!all_unknown(x).empty()) return SymShape(shape.size(), unknown_dim());
  SymShape out(shape.size());
  for (size_t k = 0; k < shape.size(); k++) {
    const SymDim& d = x->sym[k];
    if (d.kind == SymDim::Unknown) out[k] = unknown_dim();
    else if (target[k].kind == SymDim::Sym) {
      if ((d.kind == SymDim::Sym && d.sym == target[k].sym) || d.kind == SymDim::Wild || (d.kind == SymDim::Int && x->shape[k] == 1))
        out[k] = target[k];
      else
        out[k] = unknown_dim();
    } else if (d.kind == SymDim::Sym) out[k] = unknown_dim();
    else if (legacy && d.kind == SymDim::Int && x->shape[k] == 1 && shape[k] != 1) out[k] = SymDim{SymDim::Wild, nullptr};
    else out[k] = d;
  }
  return out;
}

// Reshape. Explicit (`syms` given): the symbols of the target must be those of x, as a multiset, and each keeps the size it has in
// x; any other dimension is an integer. Shape only (`syms` null): a symbolic x keeps its symbols up to the last one when the leading
// sizes are unchanged (the same elements in the same places), and is Unknown otherwise.
SymShape reshape_sym(const UOp* x, const Shape& shape, const Syms* syms) {
  const size_t r = shape.size();
  for (const SymDim& d : x->sym)
    if (d.kind == SymDim::Wild || d.kind == SymDim::Unknown) return SymShape(r, unknown_dim());
  if (!syms) {
    int last = -1;
    for (size_t k = 0; k < x->sym.size(); k++) if (x->sym[k].kind == SymDim::Sym) last = static_cast<int>(k);
    if (last < 0) return SymShape(r);
    bool same = shape.size() > static_cast<size_t>(last) && x->shape.size() > static_cast<size_t>(last);
    for (int k = 0; same && k <= last; k++) same = shape[k] == x->shape[k];
    if (!same) return SymShape(r, unknown_dim());
    SymShape out(r);
    for (int k = 0; k <= last; k++) out[k] = x->sym[k];
    return out;
  }
  SymShape out = named_shape(shape, *syms, "RESHAPE");
  std::vector<const Symbol*> have, want;
  for (const SymDim& d : x->sym) if (d.kind == SymDim::Sym) have.push_back(d.sym);
  for (const SymDim& d : out) if (d.kind == SymDim::Sym) want.push_back(d.sym);
  std::sort(have.begin(), have.end());
  std::sort(want.begin(), want.end());
  if (have != want) throw Error("RESHAPE: the symbols of " + to_string(shape) + " are not those of the input, which has " + std::to_string(have.size()) + " symbolic dimension(s)");
  for (size_t k = 0; k < r; k++) {
    if (out[k].kind != SymDim::Sym) continue;
    for (size_t j = 0; j < x->sym.size(); j++)
      if (x->sym[j].kind == SymDim::Sym && x->sym[j].sym == out[k].sym && x->shape[j] != shape[k])
        throw Error("RESHAPE: symbol " + out[k].sym->name + " is " + std::to_string(x->shape[j]) + " in the input and " + std::to_string(shape[k]) + " here");
  }
  return out;
}

// Shrink. `end_syms[k]` (empty: none) names the end of dimension k as its symbol: the whole dimension, which keeps the symbol. Any
// other cut of a symbolic dimension is an integer (the renderer needs the symbol to be at least the end then); a Wild dimension
// (a constant) stays Wild only when it is kept whole, and is Unknown otherwise.
SymShape shrink_sym(const UOp* x, const Shape& starts, const Shape& ends, const Syms& end_syms) {
  const size_t r = x->shape.size();
  if (!all_unknown(x).empty()) return SymShape(r, unknown_dim());
  SymShape out(r);
  for (size_t k = 0; k < r; k++) {
    const SymDim& d = x->sym[k];
    const bool whole = starts[k] == 0 && ends[k] == x->shape[k];
    if (k < end_syms.size() && end_syms[k]) {
      if (starts[k] != 0 || ends[k] != x->shape[k] || d.kind != SymDim::Sym || d.sym != end_syms[k])
        throw Error("SHRINK: the end of dimension " + std::to_string(k) + " is the symbol " + end_syms[k]->name +
                    ", but that is not the whole of the dimension");
      out[k] = d;
    } else if (d.kind == SymDim::Unknown) out[k] = unknown_dim();
    else if (d.kind == SymDim::Wild) out[k] = whole ? d : unknown_dim();
    else out[k] = SymDim{};
  }
  return out;
}

// Pad: a dimension that is padded is an integer if it was one; a symbolic one is Unknown (its size would be N + a constant).
SymShape pad_sym(const UOp* x, const Shape& before, const Shape& after) {
  if (!all_unknown(x).empty()) return SymShape(x->shape.size(), unknown_dim());
  SymShape out(x->shape.size());
  for (size_t k = 0; k < out.size(); k++) {
    const bool none = before[k] == 0 && after[k] == 0;
    out[k] = none ? x->sym[k] : x->sym[k].kind == SymDim::Int ? SymDim{} : unknown_dim();
  }
  return out;
}

// Permute: result dimension k is source dimension perm[k].
SymShape permute_sym_of(const UOp* x, const Shape& perm) {
  const bool unknown = !all_unknown(x).empty();
  SymShape out;
  for (int64_t p : perm) out.push_back(unknown ? unknown_dim() : x->sym[p]);
  return out;
}

// Flip: the same dimensions.
SymShape flip_sym_of(const UOp* x) { return all_unknown(x).empty() ? x->sym : SymShape(x->sym.size(), unknown_dim()); }

// Reduce over `axes` (valid for x): the reduced axes are integers of size 1.
SymShape reduce_sym_of(const UOp* x, const Shape& axes) {
  SymShape sym = all_unknown(x).empty() ? x->sym : SymShape(x->sym.size(), unknown_dim());
  for (int64_t a : axes)
    if (sym[a].kind != SymDim::Unknown) sym[a] = SymDim{};
  return sym;
}

// The symbols a node names for its dimensions, as the builders take them (nullptr where it names none).
Syms named_of(const UOp* u) { return symbols_of(u); }

// Reshape with the symbols `named` (what the node named). Not an error when they do not fit the new source: the dimensions are
// Unknown then, and the node falls back to integer loops.
SymShape reshape_rebuilt(const UOp* x, const Shape& shape, const Syms& named) {
  std::vector<const Symbol*> have, want;
  for (const SymDim& d : x->sym) if (d.kind == SymDim::Sym) have.push_back(d.sym);
  for (const Symbol* s : named) if (s) want.push_back(s);
  std::sort(have.begin(), have.end());
  std::sort(want.begin(), want.end());
  if (have != want) return SymShape(shape.size(), unknown_dim());
  return reshape_sym(x, shape, &named);
}

}  // namespace

Syms symbols_of(const UOp* u) {
  Syms out(u->sym.size(), nullptr);
  for (size_t k = 0; k < u->sym.size(); k++)
    if (u->sym[k].kind == SymDim::Sym) out[k] = u->sym[k].sym;
  return out;
}

// ---- the interning graph ----

static size_t mix(size_t h, size_t v) { return h ^ (v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2)); }

const UOp* Graph::intern(Op op, DType dt, std::vector<const UOp*> src, const Scalar& value, const std::string& name,
                         const Shape& shape, const Shape& arg, const SymShape& sym) {
  size_t h = mix(static_cast<size_t>(op), static_cast<size_t>(dt));
  for (const UOp* s : src) h = mix(h, s->id);
  for (int64_t d : shape) h = mix(h, static_cast<size_t>(d) + 1);
  for (const SymDim& d : sym) h = mix(mix(h, static_cast<size_t>(d.kind)), reinterpret_cast<size_t>(d.sym));
  h = mix(h, 0x51ed);
  for (int64_t d : arg) h = mix(h, static_cast<size_t>(d) + 1);
  if (op == Op::Const) {
    uint64_t bits;
    std::memcpy(&bits, &value.f, sizeof bits);
    h = mix(mix(h, static_cast<size_t>(value.i)), static_cast<size_t>(bits));
  }
  if (op == Op::Var) h = mix(h, std::hash<std::string>()(name));
  std::vector<const UOp*>& bucket = table_[h];
  for (const UOp* c : bucket)
    if (c->op == op && c->dtype == dt && c->src == src && c->name == name && c->shape == shape && c->arg == arg && c->sym == sym &&
        (op != Op::Const || c->value == value))
      return c;
  UOp u;
  u.op = op;
  u.dtype = dt;
  u.src = std::move(src);
  if (op == Op::Const) u.value = value;
  u.name = name;
  u.id = static_cast<uint32_t>(nodes_.size());
  u.shape = shape;
  u.sym = sym;
  u.arg = arg;
  nodes_.push_back(std::move(u));
  bucket.push_back(&nodes_.back());
  return &nodes_.back();
}

const Symbol* Graph::symbol(const std::string& name, int64_t bound) {
  if (name.empty()) throw Error("SYMBOL: the name is empty");
  if (bound < 0) throw Error("SYMBOL " + name + ": the bound " + std::to_string(bound) + " is negative");
  auto it = symtab_.find(name);
  if (it != symtab_.end()) {
    if (it->second->bound != bound)
      throw Error("SYMBOL " + name + ": asked for bound " + std::to_string(bound) + ", but it has " + std::to_string(it->second->bound));
    return it->second;
  }
  symbols_.push_back(Symbol{name, bound});
  symtab_[name] = &symbols_.back();
  return &symbols_.back();
}

const UOp* Graph::constant(const Scalar& s, const Shape& shape) {
  check_shape(shape, "CONST");
  return intern(Op::Const, s.dtype, {}, s, "", shape, {}, constant_sym(shape));
}
const UOp* Graph::var(const std::string& name, DType d, const Shape& shape) { return var(name, d, shape, Syms{}); }
const UOp* Graph::var(const std::string& name, DType d, const Shape& shape, const Syms& syms) {
  check_shape(shape, "VAR");
  return intern(Op::Var, d, {}, Scalar{}, name, shape, {}, named_shape(shape, syms, "VAR"));
}

static DType infer(Op op, const std::vector<const UOp*>& src) {
  auto bad = [&](const char* why) -> DType { throw Error(std::string(name(op)) + ": " + why); };
  if (!is_alu(op)) bad("not an ALU op");
  if (static_cast<int>(src.size()) != arity(op)) bad("wrong number of sources");
  for (const UOp* s : src) if (!s) bad("null source");
  DType d = src[0]->dtype;
  switch (op) {
    case Op::Neg: if (d == DType::Bool) bad("not defined for bool"); return d;
    case Op::Sqrt: case Op::Exp2: case Op::Log2: case Op::Sin:
    case Op::Acos: case Op::Acosh: case Op::Asin: case Op::Asinh: case Op::Atan: case Op::Atanh: case Op::Cosh: case Op::Sinh:
    case Op::Tan: case Op::Expm1: case Op::Log1p: case Op::Log10: case Op::Round:
      if (!is_float(d)) bad("float only");
      return d;
    case Op::Where:
      if (d != DType::Bool) bad("the condition must be bool");
      if (src[1]->dtype != src[2]->dtype) bad("the arms differ in dtype");
      return src[1]->dtype;
    default: break;
  }
  if (src[1]->dtype != d) bad("sources differ in dtype");
  switch (op) {
    case Op::Add: case Op::Sub: case Op::Mul: case Op::Max: if (d == DType::Bool) bad("not defined for bool"); return d;
    case Op::IDiv: case Op::Mod: case Op::Shl: case Op::Shr: if (!is_int(d)) bad("integers only"); return d;
    case Op::FDiv: case Op::Atan2: if (!is_float(d)) bad("floats only"); return d;
    case Op::CmpLt: case Op::CmpNe: return DType::Bool;
    case Op::And: case Op::Or: case Op::Xor: if (is_float(d)) bad("not defined for floats"); return d;
    default: break;
  }
  return bad("unhandled op");
}

const UOp* Graph::alu(Op op, std::vector<const UOp*> src) {
  DType d = infer(op, src);
  for (const UOp* s : src)
    if (s->shape != src[0]->shape)
      throw Error(std::string(name(op)) + ": sources differ in shape, " + to_string(src[0]->shape) + " and " + to_string(s->shape));
  Shape shape = src[0]->shape;
  SymShape sym = alu_sym(src, shape);
  return intern(op, d, std::move(src), Scalar{}, "", shape, {}, sym);
}

static const UOp* need(const UOp* x, const char* what) {
  if (!x) throw Error(std::string(what) + ": null source");
  return x;
}

const UOp* Graph::cast(const UOp* x, DType to) {
  need(x, "CAST");
  return intern(Op::Cast, to, {x}, Scalar{}, "", x->shape, {}, x->sym);
}

const UOp* Graph::reshape(const UOp* x, const Shape& shape) {
  need(x, "RESHAPE");
  check_shape(shape, "RESHAPE");
  if (numel(shape) != numel(x->shape))
    throw Error("RESHAPE: cannot reshape " + to_string(x->shape) + " into " + to_string(shape));
  return intern(Op::Reshape, x->dtype, {x}, Scalar{}, "", shape, {}, reshape_sym(x, shape, nullptr));
}

const UOp* Graph::reshape(const UOp* x, const Shape& shape, const Syms& syms) {
  need(x, "RESHAPE");
  check_shape(shape, "RESHAPE");
  if (numel(shape) != numel(x->shape))
    throw Error("RESHAPE: cannot reshape " + to_string(x->shape) + " into " + to_string(shape));
  return intern(Op::Reshape, x->dtype, {x}, Scalar{}, "", shape, {}, reshape_sym(x, shape, &syms));
}

const UOp* Graph::permute(const UOp* x, const Shape& perm) {
  need(x, "PERMUTE");
  size_t r = x->shape.size();
  std::vector<bool> seen(r, false);
  if (perm.size() != r) throw Error("PERMUTE: " + to_string(perm) + " is not a permutation of the " + std::to_string(r) + " axes");
  Shape out;
  for (int64_t p : perm) {
    if (p < 0 || p >= static_cast<int64_t>(r) || seen[p]) throw Error("PERMUTE: " + to_string(perm) + " is not a permutation of the " + std::to_string(r) + " axes");
    seen[p] = true;
    out.push_back(x->shape[p]);
  }
  return intern(Op::Permute, x->dtype, {x}, Scalar{}, "", out, perm, permute_sym_of(x, perm));
}

const UOp* Graph::expand(const UOp* x, const Shape& shape) {
  need(x, "EXPAND");
  check_shape(shape, "EXPAND");
  bool ok = shape.size() == x->shape.size();
  for (size_t k = 0; ok && k < shape.size(); k++) ok = x->shape[k] == shape[k] || x->shape[k] == 1;
  if (!ok) throw Error("EXPAND: cannot expand " + to_string(x->shape) + " to " + to_string(shape));
  return intern(Op::Expand, x->dtype, {x}, Scalar{}, "", shape, {}, expand_sym(x, shape, Syms{}, true));
}

const UOp* Graph::expand(const UOp* x, const Shape& shape, const Syms& syms) {
  need(x, "EXPAND");
  check_shape(shape, "EXPAND");
  bool ok = shape.size() == x->shape.size();
  for (size_t k = 0; ok && k < shape.size(); k++) ok = x->shape[k] == shape[k] || x->shape[k] == 1;
  if (!ok) throw Error("EXPAND: cannot expand " + to_string(x->shape) + " to " + to_string(shape));
  return intern(Op::Expand, x->dtype, {x}, Scalar{}, "", shape, {}, expand_sym(x, shape, syms, false));
}

const UOp* Graph::reduce(Op op, const UOp* x, Shape axes) {
  need(x, name(op));
  std::sort(axes.begin(), axes.end());
  Shape out = x->shape;
  for (size_t k = 0; k < axes.size(); k++) {
    if (axes[k] < 0 || axes[k] >= static_cast<int64_t>(out.size()) || (k && axes[k] == axes[k - 1]))
      throw Error(std::string(name(op)) + ": bad axes " + to_string(axes) + " for shape " + to_string(x->shape));
    out[axes[k]] = 1;
  }
  if (op == Op::ReduceSum && x->dtype == DType::Bool) throw Error("REDUCE_SUM: not defined for bool");
  return intern(op, x->dtype, {x}, Scalar{}, "", out, axes, reduce_sym_of(x, axes));
}
const UOp* Graph::reduce_sum(const UOp* x, const Shape& axes) { return reduce(Op::ReduceSum, x, axes); }
const UOp* Graph::reduce_max(const UOp* x, const Shape& axes) { return reduce(Op::ReduceMax, x, axes); }

const UOp* Graph::shrink(const UOp* x, const Shape& starts, const Shape& ends) { return shrink(x, starts, ends, Syms{}); }

const UOp* Graph::shrink(const UOp* x, const Shape& starts, const Shape& ends, const Syms& end_syms) {
  need(x, "SHRINK");
  size_t r = x->shape.size();
  if (starts.size() != r || ends.size() != r) throw Error("SHRINK: bounds for " + std::to_string(r) + " dimensions needed");
  if (!end_syms.empty() && end_syms.size() != r) throw Error("SHRINK: " + std::to_string(end_syms.size()) + " symbols for " + std::to_string(r) + " dimensions");
  Shape out, arg = starts;
  arg.insert(arg.end(), ends.begin(), ends.end());
  for (size_t k = 0; k < r; k++) {
    if (starts[k] < 0 || ends[k] > x->shape[k] || starts[k] >= ends[k])
      throw Error("SHRINK: bounds " + to_string(starts) + ".." + to_string(ends) + " do not fit shape " + to_string(x->shape));
    out.push_back(ends[k] - starts[k]);
  }
  return intern(Op::Shrink, x->dtype, {x}, Scalar{}, "", out, arg, shrink_sym(x, starts, ends, end_syms));
}

const UOp* Graph::pad(const UOp* x, const Shape& before, const Shape& after) {
  need(x, "PAD");
  size_t r = x->shape.size();
  if (before.size() != r || after.size() != r) throw Error("PAD: amounts for " + std::to_string(r) + " dimensions needed");
  Shape out, arg = before;
  arg.insert(arg.end(), after.begin(), after.end());
  for (size_t k = 0; k < r; k++) {
    if (before[k] < 0 || after[k] < 0) throw Error("PAD: negative padding");
    out.push_back(x->shape[k] + before[k] + after[k]);
  }
  check_shape(out, "PAD");
  return intern(Op::Pad, x->dtype, {x}, Scalar{}, "", out, arg, pad_sym(x, before, after));
}

const UOp* Graph::flip(const UOp* x, const Shape& axes_in) {
  need(x, "FLIP");
  Shape axes = axes_in;
  std::sort(axes.begin(), axes.end());
  for (size_t k = 0; k < axes.size(); k++)
    if (axes[k] < 0 || axes[k] >= static_cast<int64_t>(x->shape.size()) || (k && axes[k] == axes[k - 1]))
      throw Error("FLIP: bad axes " + to_string(axes_in) + " for shape " + to_string(x->shape));
  return intern(Op::Flip, x->dtype, {x}, Scalar{}, "", x->shape, axes, flip_sym_of(x));
}

// The same node over another source: a rewrite replaces a source by one that may have other symbolic dimensions (a constant is
// Wild, say), so the symbols of the node are computed again from the new source. The node keeps the symbols it names, where the
// new source has them too; a dimension that does not fit is Unknown (integer loops), never an error.
const UOp* Graph::rebuild(const UOp* u, std::vector<const UOp*> src) {
  if (u->op == Op::Const || u->op == Op::Var) return u;
  if (src.size() != 1 && arity(u->op) == 1) throw Error(std::string(name(u->op)) + ": wrong number of sources");
  if (u->op == Op::Cast) return cast(src[0], u->dtype);
  if (is_alu(u->op)) return alu(u->op, std::move(src));
  const UOp* x = src[0];
  const Syms named = named_of(u);
  bool legacy = true;   // a node without symbols of its own is a shape-only one
  for (const SymDim& d : u->sym) legacy = legacy && d.kind != SymDim::Sym;
  switch (u->op) {
    case Op::Reshape:   // a symbol that does not fit the new source makes the dimensions Unknown; the sizes must agree
      if (numel(x->shape) != numel(u->shape)) throw Error("RESHAPE: rebuilt over " + to_string(x->shape) + " for " + to_string(u->shape));
      return intern(Op::Reshape, x->dtype, {x}, Scalar{}, "", u->shape, {}, reshape_rebuilt(x, u->shape, named));
    case Op::Expand: return legacy ? expand(x, u->shape) : expand(x, u->shape, named);
    case Op::Permute: return permute(x, u->arg);
    case Op::ReduceSum: return reduce_sum(x, u->arg);
    case Op::ReduceMax: return reduce_max(x, u->arg);
    case Op::Shrink: {
      const size_t r = u->arg.size() / 2;
      Shape starts(u->arg.begin(), u->arg.begin() + r), ends(u->arg.begin() + r, u->arg.end());
      Syms end_syms(r, nullptr);   // the whole dimension keeps the symbol it had, if the new source has that symbol there
      for (size_t k = 0; k < r; k++)
        if (starts[k] == 0 && ends[k] == x->shape[k] && u->sym[k].kind == SymDim::Sym && x->sym[k] == u->sym[k]) end_syms[k] = u->sym[k].sym;
      return shrink(x, starts, ends, end_syms);
    }
    case Op::Pad: {
      const size_t r = u->arg.size() / 2;
      return pad(x, Shape(u->arg.begin(), u->arg.begin() + r), Shape(u->arg.begin() + r, u->arg.end()));
    }
    case Op::Flip: return flip(x, u->arg);
    default: break;
  }
  throw Error(std::string("rebuild: ") + name(u->op));
}

// ---- traversal ----

std::vector<const UOp*> toposort(const UOp* root) {
  std::vector<const UOp*> out;
  std::unordered_set<const UOp*> seen;
  std::vector<std::pair<const UOp*, size_t>> stack;
  stack.push_back({root, 0});
  seen.insert(root);
  while (!stack.empty()) {
    auto& top = stack.back();
    if (top.second < top.first->src.size()) {
      const UOp* s = top.first->src[top.second++];
      if (seen.insert(s).second) stack.push_back({s, 0});
    } else {
      out.push_back(top.first);
      stack.pop_back();
    }
  }
  return out;
}

std::string dump(const UOp* root) {
  std::vector<const UOp*> order = toposort(root);
  std::unordered_map<const UOp*, size_t> index;
  for (size_t k = 0; k < order.size(); k++) index[order[k]] = k;
  std::string out;
  for (size_t k = 0; k < order.size(); k++) {
    const UOp* u = order[k];
    char head[64];
    std::snprintf(head, sizeof head, "%3zu %-6s %-7s (", k, name(u->op), name(u->dtype));
    out += head;
    for (size_t j = 0; j < u->src.size(); j++) out += (j ? ", " : "") + std::to_string(index[u->src[j]]);
    out += ")";
    if (u->op == Op::Const) out += " " + to_string(u->value);
    if (u->op == Op::Var) out += " " + u->name;
    if (!u->shape.empty()) out += " shape=" + to_string(u->shape);
    if (u->op == Op::Permute) out += " perm=" + to_string(u->arg);
    if (is_reduce(u->op) || u->op == Op::Flip) out += " axes=" + to_string(u->arg);
    if (u->op == Op::Shrink || u->op == Op::Pad) {
      size_t r = u->arg.size() / 2;
      out += (u->op == Op::Shrink ? " starts=" : " before=") + to_string(Shape(u->arg.begin(), u->arg.begin() + r)) +
             (u->op == Op::Shrink ? " ends=" : " after=") + to_string(Shape(u->arg.begin() + r, u->arg.end()));
    }
    out += "\n";
  }
  return out;
}

// ---- evaluation ----

static Scalar cast_scalar(const Scalar& s, DType to) {
  return is_float(s.dtype) ? Scalar::from_double(to, s.f) : Scalar::from_int(to, s.i);
}

static int64_t wrap_add(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) + static_cast<uint64_t>(b)); }
static int64_t wrap_sub(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) - static_cast<uint64_t>(b)); }
static int64_t wrap_mul(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) * static_cast<uint64_t>(b)); }

Scalar eval_op(Op op, DType out, const std::vector<Scalar>& a) {
  if (op != Op::Cast && !is_alu(op)) throw Error(std::string(name(op)) + ": not an ALU op");
  if (static_cast<int>(a.size()) != arity(op)) throw Error(std::string(name(op)) + ": wrong number of arguments");
  if (op == Op::Cast) return cast_scalar(a[0], out);
  if (op == Op::Where) return a[0].i ? a[1] : a[2];
  const bool fl = is_float(a[0].dtype);
  switch (op) {
    case Op::Neg: return fl ? Scalar::from_double(out, -a[0].f) : Scalar::from_int(out, wrap_sub(0, a[0].i));
    case Op::Sqrt: return Scalar::from_double(out, std::sqrt(a[0].f));
    case Op::Exp2: return Scalar::from_double(out, std::exp2(a[0].f));
    case Op::Log2: return Scalar::from_double(out, std::log2(a[0].f));
    case Op::Sin: return Scalar::from_double(out, std::sin(a[0].f));
    case Op::Acos: return Scalar::from_double(out, std::acos(a[0].f));
    case Op::Acosh: return Scalar::from_double(out, std::acosh(a[0].f));
    case Op::Asin: return Scalar::from_double(out, std::asin(a[0].f));
    case Op::Asinh: return Scalar::from_double(out, std::asinh(a[0].f));
    case Op::Atan: return Scalar::from_double(out, std::atan(a[0].f));
    case Op::Atanh: return Scalar::from_double(out, std::atanh(a[0].f));
    case Op::Cosh: return Scalar::from_double(out, std::cosh(a[0].f));
    case Op::Sinh: return Scalar::from_double(out, std::sinh(a[0].f));
    case Op::Tan: return Scalar::from_double(out, std::tan(a[0].f));
    case Op::Expm1: return Scalar::from_double(out, std::expm1(a[0].f));
    case Op::Log1p: return Scalar::from_double(out, std::log1p(a[0].f));
    case Op::Log10: return Scalar::from_double(out, std::log10(a[0].f));
    case Op::Round: return Scalar::from_double(out, std::nearbyint(a[0].f));   // ties to even under the default rounding mode
    case Op::Atan2: return Scalar::from_double(out, std::atan2(a[0].f, a[1].f));
    case Op::Shl: case Op::Shr: {
      // numpy's rule: a count below 0 or at least the width gives 0 for a left shift, and for a right shift the sign fill (0 or -1).
      // Shr is arithmetic: the values are sign extended, and C++20 defines >> on negative values as arithmetic.
      const int64_t width = out == DType::Int32 ? 32 : 64, count = a[1].i;
      if (op == Op::Shl)
        return Scalar::from_int(out, count < 0 || count >= width ? 0 : static_cast<int64_t>(static_cast<uint64_t>(a[0].i) << count));
      return Scalar::from_int(out, count < 0 || count >= width ? (a[0].i < 0 ? -1 : 0) : a[0].i >> count);
    }
    case Op::Add: return fl ? Scalar::from_double(out, a[0].f + a[1].f) : Scalar::from_int(out, wrap_add(a[0].i, a[1].i));
    case Op::Sub: return fl ? Scalar::from_double(out, a[0].f - a[1].f) : Scalar::from_int(out, wrap_sub(a[0].i, a[1].i));
    case Op::Mul: return fl ? Scalar::from_double(out, a[0].f * a[1].f) : Scalar::from_int(out, wrap_mul(a[0].i, a[1].i));
    case Op::Max:
      return fl ? Scalar::from_double(out, std::isnan(a[0].f) ? a[1].f : std::isnan(a[1].f) ? a[0].f : (a[0].f > a[1].f ? a[0].f : a[1].f))
                : Scalar::from_int(out, a[0].i > a[1].i ? a[0].i : a[1].i);
    case Op::FDiv: return Scalar::from_double(out, a[0].f / a[1].f);
    case Op::IDiv:
    case Op::Mod: {
      if (a[1].i == 0) throw Error(std::string(name(op)) + ": integer division by zero");
      if (a[1].i == -1) return Scalar::from_int(out, op == Op::IDiv ? wrap_sub(0, a[0].i) : 0);  // INT_MIN / -1 wraps
      return Scalar::from_int(out, op == Op::IDiv ? a[0].i / a[1].i : a[0].i % a[1].i);
    }
    case Op::CmpLt: return Scalar::from_int(DType::Bool, fl ? a[0].f < a[1].f : a[0].i < a[1].i);
    case Op::CmpNe: return Scalar::from_int(DType::Bool, fl ? a[0].f != a[1].f : a[0].i != a[1].i);
    case Op::And: return Scalar::from_int(out, a[0].i & a[1].i);
    case Op::Or: return Scalar::from_int(out, a[0].i | a[1].i);
    case Op::Xor: return Scalar::from_int(out, a[0].i ^ a[1].i);
    default: break;
  }
  throw Error(std::string(name(op)) + ": unhandled op");
}

Array Array::full(DType d, const Shape& shape, const Scalar& v) {
  if (v.dtype != d) throw Error("Array::full: value is " + std::string(name(v.dtype)) + ", not " + name(d));
  check_shape(shape, "Array");
  return Array(d, shape, std::vector<Scalar>(static_cast<size_t>(numel(shape)), v));
}

Array Array::from_doubles(DType d, const Shape& shape, const std::vector<double>& v) {
  check_shape(shape, "Array");
  if (static_cast<int64_t>(v.size()) != numel(shape))
    throw Error("Array::from_doubles: " + std::to_string(v.size()) + " values for shape " + to_string(shape));
  Array a;
  a.dtype = d;
  a.shape = shape;
  for (double x : v) a.data.push_back(Scalar::from_double(d, x));
  return a;
}

static std::vector<int64_t> strides_of(const Shape& s) {
  std::vector<int64_t> st(s.size(), 1);
  for (size_t k = s.size(); k-- > 1;) st[k - 1] = st[k] * s[k];
  return st;
}

// The elements of `out` shape in row-major order, each as the flat index into a source whose element for
// output coordinate c is at sum(c[k] * mult[k]).
template <class F>
static void for_each_index(const Shape& out, const std::vector<int64_t>& mult, F f, int64_t base = 0) {
  int64_t n = numel(out);
  std::vector<int64_t> c(out.size(), 0);
  int64_t src = base;
  for (int64_t i = 0; i < n; i++) {
    f(i, src);
    for (size_t k = out.size(); k-- > 0;) {
      src += mult[k];
      if (++c[k] < out[k]) break;
      src -= mult[k] * out[k];
      c[k] = 0;
    }
  }
}

static Array eval_node(const UOp* u, const std::vector<const Array*>& in, const std::map<std::string, Array>& vars) {
  Array out;
  out.dtype = u->dtype;
  out.shape = u->shape;
  switch (u->op) {
    case Op::Const: return Array::full(u->dtype, u->shape, u->value);
    case Op::Var: {
      auto it = vars.find(u->name);
      if (it == vars.end()) throw Error("unbound variable " + u->name);
      if (it->second.dtype != u->dtype)
        throw Error("variable " + u->name + " is " + name(u->dtype) + ", bound to a " + name(it->second.dtype));
      if (it->second.shape != u->shape)
        throw Error("variable " + u->name + " has shape " + to_string(u->shape) + ", bound to " + to_string(it->second.shape));
      return it->second;
    }
    case Op::Reshape: out.data = in[0]->data; return out;
    case Op::Permute: {
      std::vector<int64_t> st = strides_of(in[0]->shape), mult;
      for (int64_t p : u->arg) mult.push_back(st[p]);
      out.data.resize(in[0]->data.size());
      for_each_index(out.shape, mult, [&](int64_t i, int64_t s) { out.data[i] = in[0]->data[s]; });
      return out;
    }
    case Op::Expand: {
      std::vector<int64_t> st = strides_of(in[0]->shape), mult;
      for (size_t k = 0; k < st.size(); k++) mult.push_back(in[0]->shape[k] == 1 ? 0 : st[k]);
      out.data.resize(static_cast<size_t>(numel(out.shape)));
      for_each_index(out.shape, mult, [&](int64_t i, int64_t s) { out.data[i] = in[0]->data[s]; });
      return out;
    }
    case Op::Shrink: {
      std::vector<int64_t> st = strides_of(in[0]->shape);
      int64_t base = 0;
      for (size_t k = 0; k < st.size(); k++) base += u->arg[k] * st[k];
      out.data.resize(static_cast<size_t>(numel(out.shape)));
      for_each_index(out.shape, st, [&](int64_t i, int64_t s) { out.data[i] = in[0]->data[s]; }, base);
      return out;
    }
    case Op::Pad: {
      std::vector<int64_t> st = strides_of(out.shape);
      int64_t base = 0;
      for (size_t k = 0; k < st.size(); k++) base += u->arg[k] * st[k];
      out.data.assign(static_cast<size_t>(numel(out.shape)), Scalar::from_int(u->dtype, 0));
      for_each_index(in[0]->shape, st, [&](int64_t i, int64_t o) { out.data[o] = in[0]->data[i]; }, base);
      return out;
    }
    case Op::Flip: {
      std::vector<int64_t> st = strides_of(in[0]->shape), mult = st;
      int64_t base = 0;
      for (int64_t ax : u->arg) { base += (in[0]->shape[ax] - 1) * st[ax]; mult[ax] = -st[ax]; }
      out.data.resize(in[0]->data.size());
      for_each_index(out.shape, mult, [&](int64_t i, int64_t s) { out.data[i] = in[0]->data[s]; }, base);
      return out;
    }
    case Op::ReduceSum:
    case Op::ReduceMax: {
      const Array& a = *in[0];
      std::vector<int64_t> ost = strides_of(out.shape), mult(a.shape.size());
      for (size_t k = 0; k < mult.size(); k++) mult[k] = out.shape[k] == 1 ? 0 : ost[k];
      std::vector<bool> have(static_cast<size_t>(numel(out.shape)), false);
      out.data.resize(have.size());
      const Op bin = u->op == Op::ReduceSum ? Op::Add : Op::Max;
      for_each_index(a.shape, mult, [&](int64_t i, int64_t o) {
        if (!have[o]) { out.data[o] = a.data[i]; have[o] = true; }
        else out.data[o] = eval_op(bin, u->dtype, {out.data[o], a.data[i]});
      });
      return out;
    }
    default: break;
  }
  size_t n = in[0]->data.size();
  out.data.reserve(n);
  std::vector<Scalar> args(in.size());
  for (size_t i = 0; i < n; i++) {
    for (size_t k = 0; k < in.size(); k++) args[k] = in[k]->data[i];
    out.data.push_back(eval_op(u->op, u->dtype, args));
  }
  return out;
}

Array evaluate_array(const UOp* root, const std::map<std::string, Array>& vars) {
  std::unordered_map<const UOp*, Array> val;
  for (const UOp* u : toposort(root)) {
    std::vector<const Array*> in;
    for (const UOp* s : u->src) in.push_back(&val[s]);
    Array r = eval_node(u, in, vars);
    val[u] = std::move(r);
  }
  return val[root];
}

Scalar evaluate(const UOp* root, const std::map<std::string, Scalar>& vars) {
  if (!root->shape.empty()) throw Error("evaluate: the result has shape " + to_string(root->shape) + "; use evaluate_array");
  std::map<std::string, Array> arrays;
  for (const auto& kv : vars) arrays[kv.first] = Array(kv.second.dtype, {}, {kv.second});
  return evaluate_array(root, arrays).data[0];
}

}  // namespace nfcuop
