// nfcuop core: dtypes, scalars, the interning Graph, the reference interpreter. See nfcuop.hpp.
#include "nfcuop.hpp"

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

static const char* const kOpNames[] = {"CONST", "VAR", "NEG", "SQRT", "EXP2", "LOG2", "SIN", "ADD", "SUB",
                                       "MUL",   "IDIV", "FDIV", "MOD", "MAX", "CMPLT", "CMPNE", "AND", "OR",
                                       "XOR",   "WHERE", "CAST"};
static_assert(sizeof(kOpNames) / sizeof(kOpNames[0]) == static_cast<size_t>(Op::Count_), "op name table");
const char* name(Op op) { return kOpNames[static_cast<int>(op)]; }

int arity(Op op) {
  switch (op) {
    case Op::Const: case Op::Var: return 0;
    case Op::Neg: case Op::Sqrt: case Op::Exp2: case Op::Log2: case Op::Sin: case Op::Cast: return 1;
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

static size_t mix(size_t h, size_t v) { return h ^ (v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2)); }

const UOp* Graph::intern(Op op, DType dt, std::vector<const UOp*> src, const Scalar& value, const std::string& name) {
  size_t h = mix(static_cast<size_t>(op), static_cast<size_t>(dt));
  for (const UOp* s : src) h = mix(h, s->id);
  if (op == Op::Const) {
    uint64_t bits;
    std::memcpy(&bits, &value.f, sizeof bits);
    h = mix(mix(h, static_cast<size_t>(value.i)), static_cast<size_t>(bits));
  }
  if (op == Op::Var) h = mix(h, std::hash<std::string>()(name));
  std::vector<const UOp*>& bucket = table_[h];
  for (const UOp* c : bucket)
    if (c->op == op && c->dtype == dt && c->src == src && c->name == name && (op != Op::Const || c->value == value)) return c;
  nodes_.push_back(UOp{op, dt, std::move(src), op == Op::Const ? value : Scalar{}, name, static_cast<uint32_t>(nodes_.size())});
  bucket.push_back(&nodes_.back());
  return &nodes_.back();
}

const UOp* Graph::constant(const Scalar& s) { return intern(Op::Const, s.dtype, {}, s, ""); }
const UOp* Graph::var(const std::string& name, DType d) { return intern(Op::Var, d, {}, Scalar{}, name); }

static DType infer(Op op, const std::vector<const UOp*>& src) {
  auto bad = [&](const char* why) -> DType { throw Error(std::string(name(op)) + ": " + why); };
  if (!is_alu(op)) bad("not an ALU op");
  if (static_cast<int>(src.size()) != arity(op)) bad("wrong number of sources");
  for (const UOp* s : src) if (!s) bad("null source");
  DType d = src[0]->dtype;
  switch (op) {
    case Op::Neg: if (d == DType::Bool) bad("not defined for bool"); return d;
    case Op::Sqrt: case Op::Exp2: case Op::Log2: case Op::Sin: if (!is_float(d)) bad("float only"); return d;
    case Op::Where:
      if (d != DType::Bool) bad("the condition must be bool");
      if (src[1]->dtype != src[2]->dtype) bad("the arms differ in dtype");
      return src[1]->dtype;
    default: break;
  }
  if (src[1]->dtype != d) bad("sources differ in dtype");
  switch (op) {
    case Op::Add: case Op::Sub: case Op::Mul: case Op::Max: if (d == DType::Bool) bad("not defined for bool"); return d;
    case Op::IDiv: case Op::Mod: if (!is_int(d)) bad("integers only"); return d;
    case Op::FDiv: if (!is_float(d)) bad("floats only"); return d;
    case Op::CmpLt: case Op::CmpNe: return DType::Bool;
    case Op::And: case Op::Or: case Op::Xor: if (is_float(d)) bad("not defined for floats"); return d;
    default: break;
  }
  return bad("unhandled op");
}

const UOp* Graph::alu(Op op, std::vector<const UOp*> src) {
  DType d = infer(op, src);
  return intern(op, d, std::move(src), Scalar{}, "");
}

const UOp* Graph::cast(const UOp* x, DType to) {
  if (!x) throw Error("CAST: null source");
  return intern(Op::Cast, to, {x}, Scalar{}, "");
}

const UOp* Graph::rebuild(const UOp* u, std::vector<const UOp*> src) {
  if (u->op == Op::Const || u->op == Op::Var) return u;
  if (u->op == Op::Cast) {
    if (src.size() != 1) throw Error("CAST: wrong number of sources");
    return cast(src[0], u->dtype);
  }
  return alu(u->op, std::move(src));
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
    case Op::Add: return fl ? Scalar::from_double(out, a[0].f + a[1].f) : Scalar::from_int(out, wrap_add(a[0].i, a[1].i));
    case Op::Sub: return fl ? Scalar::from_double(out, a[0].f - a[1].f) : Scalar::from_int(out, wrap_sub(a[0].i, a[1].i));
    case Op::Mul: return fl ? Scalar::from_double(out, a[0].f * a[1].f) : Scalar::from_int(out, wrap_mul(a[0].i, a[1].i));
    case Op::Max:
      return fl ? Scalar::from_double(out, std::fmax(a[0].f, a[1].f)) : Scalar::from_int(out, a[0].i > a[1].i ? a[0].i : a[1].i);
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

Scalar evaluate(const UOp* root, const std::map<std::string, Scalar>& vars) {
  std::unordered_map<const UOp*, Scalar> val;
  for (const UOp* u : toposort(root)) {
    if (u->op == Op::Const) {
      val[u] = u->value;
    } else if (u->op == Op::Var) {
      auto it = vars.find(u->name);
      if (it == vars.end()) throw Error("unbound variable " + u->name);
      if (it->second.dtype != u->dtype)
        throw Error("variable " + u->name + " is " + name(u->dtype) + ", bound to a " + name(it->second.dtype));
      val[u] = it->second;
    } else {
      std::vector<Scalar> args;
      for (const UOp* s : u->src) args.push_back(val[s]);
      val[u] = eval_op(u->op, u->dtype, args);
    }
  }
  return val[root];
}

}  // namespace nfcuop
