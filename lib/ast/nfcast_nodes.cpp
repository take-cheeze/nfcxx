// nfcast: the AST nodes. Every node evaluates itself. The ones that dispatch on the types they see (arithmetic, comparison,
// indexing, field access, calls, method calls) start as an "uninitialized" node: on its first evaluation it looks at the
// operands, replaces itself in its parent by a specialized node (integer addition, a table field with an inline cache, a
// host-object member with a cached lookup, a call of a closure), and carries on. A specialized node guards what it assumed;
// when a guard fails it replaces itself by the generic node, which handles everything.
//
// Garbage collection: a node that keeps a collectable value in a C++ local while it evaluates another operand roots it first
// (Pushed puts it on the interpreter's stack). The collector runs only at safe points (a function entry, a loop iteration).
#include <atomic>
#include <cmath>

#include "nfcast_impl.hpp"

namespace nfcast {

static std::atomic<std::uint64_t> g_proto_uid{0};
Proto::Proto() : uid(++g_proto_uid) {}
Proto::~Proto() {
  if (tier) tier_free(tier);
  for (Proto* c : children) c->release();
}

namespace {

const int kStackSlack = 512;

// Roots a value on the stack for the lifetime of the object.
struct Pushed {
  State& S;
  Value* mark;
  Pushed(State& s, const Value& v) : S(s), mark(s.top) {
    *s.top = v;
    ++s.top;
  }
  ~Pushed() { S.top = mark; }
  Pushed(const Pushed&) = delete;
  Pushed& operator=(const Pushed&) = delete;
};

// Replace SELF in its parent by a new node of type N (allocated in the arena of the function the node belongs to: for a node in
// an inlined body, the function it was inlined into).
template <class N, class... A>
N* respec(Frame& f, Node* self, A&&... a) {
  N* n = owner_proto(f)->make<N>(static_cast<A&&>(a)...);
  self->rewire(n);
  ++f.S->stats.rewrites;
  return n;
}

inline void check_stack(State& S, std::size_t n) {
  if (S.top + n + kStackSlack > S.stack_end) S.rt_error("stack overflow");
}

// A node that is only a name for error messages ("method 'foo'").
struct NameNode : Node {
  std::string d;
  explicit NameNode(std::string s) : d(std::move(s)) {}
  Value eval(Frame&) override { return Value(); }
  void describe(std::string& out) const override { out = d; }
};

// ================================================================================================================
// leaves
// ================================================================================================================
struct ConstNode : Node {
  Value v;
  explicit ConstNode(const Value& x) : v(x) {}
  Value eval(Frame&) override { return v; }
  bool is_simple() const override { return true; }
  int node_kind() const override { return 1; }
  void describe(std::string& out) const override {
    if (v.t == T_STR) out = "constant '" + std::string(v.s()->view()) + "'";
  }
  bool const_number(Value* out) const override {
    if (!v.is_number()) return false;
    *out = v;
    return true;
  }
  int expkind() const override { return v.truthy() ? 1 : 2; }
};

struct LocalNode : Node {
  VarInfo* vi;
  int slot;
  bool cell = false;
  std::string name;
  LocalNode(Proto& P, VarInfo* v) : vi(v), slot(v->slot), name(v->name) { P.patchables.push_back(this); }
  void patch() override {
    cell = vi->captured;
    vi = nullptr;
  }
  Value eval(Frame& f) override {
    const Value& s = f.base[slot];
    return cell ? static_cast<Cell*>(s.o)->v : s;
  }
  bool is_simple() const override { return true; }
  void describe(std::string& out) const override { out = "local '" + name + "'"; }
  int target_kind() const override { return 1; }
  VarInfo* target_var() const override { return vi; }
  void assign(Frame& f, const Value& v) {
    Value& s = f.base[slot];
    if (cell) static_cast<Cell*>(s.o)->v = v;
    else s = v;
  }
};

struct UpvalNode : Node {
  int idx;
  std::string name;
  UpvalNode(int i, std::string n) : idx(i), name(std::move(n)) {}
  Value eval(Frame& f) override { return f.cl->up[idx]->v; }
  bool is_simple() const override { return true; }
  void describe(std::string& out) const override { out = "upvalue '" + name + "'"; }
  int target_kind() const override { return 2; }
  int upval_index() const override { return idx; }
};

struct GlobalNode : Node {
  String* name;
  long cache = -1;
  explicit GlobalNode(String* n) : name(n) {}
  void describe(std::string& out) const override { out = "global '" + std::string(name->view()) + "'"; }
  int target_kind() const override { return 3; }
  Value eval(Frame& f) override {
    Table* g = f.S->globals;
    long i = cache;
    if (static_cast<unsigned long>(i) < g->hcap && g->nodes[i].key.t == T_STR && g->nodes[i].key.o == name) {
      const Value& v = g->nodes[i].val;
      if (!v.is_nil()) return v;
    } else {
      i = g->find_str(name);
      if (i >= 0) {
        cache = i;
        const Value& v = g->nodes[i].val;
        if (!v.is_nil()) return v;
      }
    }
    if (!g->meta) return Value();
    f.line = line;
    return index_slow(*f.S, Value::table(g), Value::str(name), nullptr);
  }
  void assign(Frame& f, const Value& v) {
    State& S = *f.S;
    Table* g = S.globals;
    long i = cache;
    if (!(static_cast<unsigned long>(i) < g->hcap && g->nodes[i].key.t == T_STR && g->nodes[i].key.o == name)) {
      i = g->find_str(name);
      if (i >= 0) cache = i;
    }
    if (i >= 0 && !g->nodes[i].val.is_nil()) {
      g->nodes[i].val = v;
      g->absent = 0;
      return;
    }
    if (!g->meta) {
      g->set_str(S, name, v);
      return;
    }
    f.line = line;
    setindex_slow(S, Value::table(g), Value::str(name), v, nullptr);
  }
};

struct VarargNode : Node {
  Value eval(Frame& f) override { return f.nva > 0 ? f.va[0] : Value(); }
  void evalMulti(Frame& f, Rets& out) override {
    for (int i = 0; i < f.nva; ++i) out.push(f.va[i]);
  }
  bool is_multi() const override { return true; }
  bool is_simple() const override { return true; }
};

struct FunctionNode : Node {
  Proto* child;
  explicit FunctionNode(Proto* c) : child(c) {}
  Value eval(Frame& f) override {
    State& S = *f.S;
    std::uint32_t nup = static_cast<std::uint32_t>(child->upvals.size());
    Closure* cl = new_closure(S, child, nup);
    for (std::uint32_t i = 0; i < nup; ++i) {
      const UpvalDesc& d = child->upvals[i];
      if (d.from_local) {
        const Value& s = f.base[d.index];
        if (s.t != T_CELL) {
          f.line = line;
          S.rt_error("internal error: captured local '" + d.name + "' is not boxed");
        }
        cl->up[i] = static_cast<Cell*>(s.o);
      } else {
        cl->up[i] = f.cl->up[d.index];
      }
    }
    return Value::function(cl);
  }
};

struct ParenNode : Node {
  Node* e_;
  explicit ParenNode(Node* e) : e_(e) { adopt(e_); }
  Value eval(Frame& f) override { return e_->eval(f); }
  bool is_simple() const override { return e_->is_simple(); }
  void describe(std::string& out) const override { e_->describe(out); }
};

// ================================================================================================================
// arithmetic
// ================================================================================================================
inline bool is_int_op(int op) { return op == AR_ADD || op == AR_SUB || op == AR_MUL || op == AR_MOD || op == AR_IDIV; }
inline bool is_bit_op(int op) { return op == AR_BAND || op == AR_BOR || op == AR_BXOR || op == AR_SHL || op == AR_SHR; }

// Integer arithmetic of an operator (may raise for // and %).
template <int OP>
inline Value ar_ii(State& S, std::int64_t a, std::int64_t b) {
  std::uint64_t x = static_cast<std::uint64_t>(a), y = static_cast<std::uint64_t>(b);
  switch (OP) {
    case AR_ADD: return Value::integer(static_cast<std::int64_t>(x + y));
    case AR_SUB: return Value::integer(static_cast<std::int64_t>(x - y));
    case AR_MUL: return Value::integer(static_cast<std::int64_t>(x * y));
    case AR_MOD: return Value::integer(int_mod(S, a, b));
    case AR_IDIV: return Value::integer(int_floordiv(S, a, b));
    case AR_BAND: return Value::integer(a & b);
    case AR_BOR: return Value::integer(a | b);
    case AR_BXOR: return Value::integer(a ^ b);
    case AR_SHL: return Value::integer(shift_left(a, b));
    case AR_SHR: return Value::integer(shift_left(a, static_cast<std::int64_t>(0u - y)));
    default: return Value();
  }
}

inline double num_d(const Value& v) { return v.t == T_INT ? static_cast<double>(v.i) : v.d; }

template <int OP>
inline Value ar_nn(State& S, const Value& a, const Value& b) {
  (void)S;
  double x = num_d(a), y = num_d(b);
  switch (OP) {
    case AR_ADD: return Value::number(x + y);
    case AR_SUB: return Value::number(x - y);
    case AR_MUL: return Value::number(x * y);
    case AR_DIV: return Value::number(x / y);
    case AR_POW: return Value::number(flt_pow(x, y));
    case AR_MOD: return Value::number(flt_mod(x, y));
    case AR_IDIV: return Value::number(std::floor(x / y));
    default: return Value();
  }
}

struct ArithBase : Node {
  int op;
  Node *l_, *r_;
  ArithBase(int o, Node* l, Node* r) : op(o), l_(l), r_(r) {
    adopt(l_);
    adopt(r_);
  }
  // Evaluates the operands left to right, keeping the first rooted while the second runs, then computes.
  Value eval(Frame& f) override {
    Value a = l_->eval(f), b;
    if (a.is_gc() && !r_->is_simple()) {
      Pushed p(*f.S, a);
      b = r_->eval(f);
    } else {
      b = r_->eval(f);
    }
    return compute(f, a, b);
  }
  virtual Value compute(Frame& f, const Value& a, const Value& b) = 0;
  Value generic(Frame& f, const Value& a, const Value& b) {
    f.line = line;
    return arith_slow(*f.S, op, a, b, l_, r_);
  }
};

struct ArithGen : ArithBase {
  using ArithBase::ArithBase;
  Value compute(Frame& f, const Value& a, const Value& b) override { return generic(f, a, b); }
};

ArithBase* make_ii(Frame& f, Node* self, int op, Node* l, Node* r);
ArithBase* make_nn(Frame& f, Node* self, int op, Node* l, Node* r);

template <int OP>
struct ArithII : ArithBase {
  ArithII(Node* l, Node* r) : ArithBase(OP, l, r) {}
  Value compute(Frame& f, const Value& a, const Value& b) override {
    if (a.t == T_INT && b.t == T_INT) {
      if (OP == AR_MOD || OP == AR_IDIV) f.line = line;
      return ar_ii<OP>(*f.S, a.i, b.i);
    }
    ++f.S->stats.deopts;
    ArithBase* n = (!is_bit_op(OP) && a.is_number() && b.is_number()) ? make_nn(f, this, op, l_, r_)
                                                                      : respec<ArithGen>(f, this, op, l_, r_);
    return n->compute(f, a, b);
  }
};

template <int OP>
struct ArithNN : ArithBase {
  ArithNN(Node* l, Node* r) : ArithBase(OP, l, r) {}
  Value compute(Frame& f, const Value& a, const Value& b) override {
    if (a.is_number() && b.is_number()) {
      if (OP == AR_ADD || OP == AR_SUB || OP == AR_MUL || OP == AR_MOD || OP == AR_IDIV) {
        if (a.t == T_INT && b.t == T_INT) {
          if (OP == AR_MOD || OP == AR_IDIV) f.line = line;
          return ar_ii<(OP == AR_ADD || OP == AR_SUB || OP == AR_MUL || OP == AR_MOD || OP == AR_IDIV) ? OP : AR_ADD>(*f.S, a.i, b.i);
        }
      }
      return ar_nn<OP>(*f.S, a, b);
    }
    ++f.S->stats.deopts;
    return respec<ArithGen>(f, this, op, l_, r_)->compute(f, a, b);
  }
};

ArithBase* make_ii(Frame& f, Node* self, int op, Node* l, Node* r) {
  switch (op) {
    case AR_ADD: return respec<ArithII<AR_ADD>>(f, self, l, r);
    case AR_SUB: return respec<ArithII<AR_SUB>>(f, self, l, r);
    case AR_MUL: return respec<ArithII<AR_MUL>>(f, self, l, r);
    case AR_MOD: return respec<ArithII<AR_MOD>>(f, self, l, r);
    case AR_IDIV: return respec<ArithII<AR_IDIV>>(f, self, l, r);
    case AR_BAND: return respec<ArithII<AR_BAND>>(f, self, l, r);
    case AR_BOR: return respec<ArithII<AR_BOR>>(f, self, l, r);
    case AR_BXOR: return respec<ArithII<AR_BXOR>>(f, self, l, r);
    case AR_SHL: return respec<ArithII<AR_SHL>>(f, self, l, r);
    case AR_SHR: return respec<ArithII<AR_SHR>>(f, self, l, r);
    default: return respec<ArithGen>(f, self, op, l, r);
  }
}

ArithBase* make_nn(Frame& f, Node* self, int op, Node* l, Node* r) {
  switch (op) {
    case AR_ADD: return respec<ArithNN<AR_ADD>>(f, self, l, r);
    case AR_SUB: return respec<ArithNN<AR_SUB>>(f, self, l, r);
    case AR_MUL: return respec<ArithNN<AR_MUL>>(f, self, l, r);
    case AR_DIV: return respec<ArithNN<AR_DIV>>(f, self, l, r);
    case AR_POW: return respec<ArithNN<AR_POW>>(f, self, l, r);
    case AR_MOD: return respec<ArithNN<AR_MOD>>(f, self, l, r);
    case AR_IDIV: return respec<ArithNN<AR_IDIV>>(f, self, l, r);
    default: return respec<ArithGen>(f, self, op, l, r);
  }
}

// The first evaluation of an arithmetic operator: look at the operands and pick.
struct ArithUninit : ArithBase {
  using ArithBase::ArithBase;
  Value compute(Frame& f, const Value& a, const Value& b) override {
    ArithBase* n;
    if (a.t == T_INT && b.t == T_INT && (is_int_op(op) || is_bit_op(op))) n = make_ii(f, this, op, l_, r_);
    else if (a.is_number() && b.is_number() && !is_bit_op(op)) n = make_nn(f, this, op, l_, r_);
    else n = respec<ArithGen>(f, this, op, l_, r_);
    return n->compute(f, a, b);
  }
};

struct UnaryNode : Node {
  int op;
  Node* e_;
  UnaryNode(int o, Node* e) : op(o), e_(e) { adopt(e_); }
  Value eval(Frame& f) override {
    Value v = e_->eval(f);
    switch (op) {
      case OPX_NOT: return Value::boolean(!v.truthy());
      case AR_UNM:
        if (v.t == T_INT) return Value::integer(static_cast<std::int64_t>(0u - static_cast<std::uint64_t>(v.i)));
        if (v.t == T_FLT) return Value::number(-v.d);
        break;
      case OPX_LEN:
        if (v.t == T_STR) return Value::integer(v.s()->len);
        if (v.t == T_TAB && !v.tab()->meta) return Value::integer(v.tab()->length());
        f.line = line;
        return len_slow(*f.S, v, e_);
      case AR_BNOT:
        if (v.t == T_INT) return Value::integer(~v.i);
        break;
      default: break;
    }
    f.line = line;
    return arith_slow(*f.S, op, v, v, e_, e_);
  }
};

struct AndNode : Node {
  Node *l_, *r_;
  AndNode(Node* l, Node* r) : l_(l), r_(r) {
    adopt(l_);
    adopt(r_);
  }
  Value eval(Frame& f) override {
    Value a = l_->eval(f);
    return a.truthy() ? r_->eval(f) : a;
  }
  // Lua's compiler emits no test for a constant that is true on the left of `and`, and the right operand supplies the value; its
  // debug information then names that operand.
  void describe(std::string& out) const override {
    if (l_->expkind() == 1) r_->describe(out);
  }
  int expkind() const override { return r_->expkind(); }
};

struct OrNode : Node {
  Node *l_, *r_;
  OrNode(Node* l, Node* r) : l_(l), r_(r) {
    adopt(l_);
    adopt(r_);
  }
  Value eval(Frame& f) override {
    Value a = l_->eval(f);
    return a.truthy() ? a : r_->eval(f);
  }
  void describe(std::string& out) const override {
    if (l_->expkind() == 2) r_->describe(out);  // nil or false on the left: no test, the right operand is the value
  }
  int expkind() const override { return r_->expkind(); }
};

struct ConcatNode : Node {
  std::vector<Node*> parts_;
  explicit ConcatNode(std::vector<Node*> p) : parts_(std::move(p)) {
    for (Node*& n : parts_) adopt(n);
  }
  bool concat_parts(std::vector<Node*>* out) override {
    for (Node* n : parts_) out->push_back(n);
    return true;
  }
  Value eval(Frame& f) override {
    State& S = *f.S;
    int n = static_cast<int>(parts_.size());
    check_stack(S, static_cast<std::size_t>(n));
    Value* base = S.top;
    for (int i = 0; i < n; ++i) {
      base[i] = parts_[static_cast<std::size_t>(i)]->eval(f);
      S.top = base + i + 1;
    }
    f.line = line;
    Value r = concat_slow(S, base, n, parts_.data());
    S.top = base;
    return r;
  }
};

// ================================================================================================================
// comparison
// ================================================================================================================
inline bool cmp_ii(int op, std::int64_t a, std::int64_t b) {
  switch (op) {
    case CMP_LT: return a < b;
    case CMP_LE: return a <= b;
    case CMP_GT: return a > b;
    default: return a >= b;
  }
}

struct CmpBase : Node {
  int op;
  Node *l_, *r_;
  CmpBase(int o, Node* l, Node* r) : op(o), l_(l), r_(r) {
    adopt(l_);
    adopt(r_);
  }
  Value eval(Frame& f) override {
    Value a = l_->eval(f), b;
    if (a.is_gc() && !r_->is_simple()) {
      Pushed p(*f.S, a);
      b = r_->eval(f);
    } else {
      b = r_->eval(f);
    }
    return compute(f, a, b);
  }
  virtual Value compute(Frame& f, const Value& a, const Value& b) = 0;
  Value generic(Frame& f, const Value& a, const Value& b) {
    f.line = line;
    switch (op) {
      case CMP_LT: return Value::boolean(less_slow(*f.S, a, b));
      case CMP_LE: return Value::boolean(lesseq_slow(*f.S, a, b));
      case CMP_GT: return Value::boolean(less_slow(*f.S, b, a));
      default: return Value::boolean(lesseq_slow(*f.S, b, a));
    }
  }
};

struct CmpGen : CmpBase {
  using CmpBase::CmpBase;
  Value compute(Frame& f, const Value& a, const Value& b) override { return generic(f, a, b); }
};

template <int OP>
struct CmpII : CmpBase {
  CmpII(Node* l, Node* r) : CmpBase(OP, l, r) {}
  Value compute(Frame& f, const Value& a, const Value& b) override {
    if (a.t == T_INT && b.t == T_INT) return Value::boolean(cmp_ii(OP, a.i, b.i));
    ++f.S->stats.deopts;
    return respec<CmpGen>(f, this, op, l_, r_)->compute(f, a, b);
  }
};

template <int OP>
struct CmpFF : CmpBase {  // both floats
  CmpFF(Node* l, Node* r) : CmpBase(OP, l, r) {}
  Value compute(Frame& f, const Value& a, const Value& b) override {
    if (a.t == T_FLT && b.t == T_FLT) {
      switch (OP) {
        case CMP_LT: return Value::boolean(a.d < b.d);
        case CMP_LE: return Value::boolean(a.d <= b.d);
        case CMP_GT: return Value::boolean(a.d > b.d);
        default: return Value::boolean(a.d >= b.d);
      }
    }
    ++f.S->stats.deopts;
    return respec<CmpGen>(f, this, op, l_, r_)->compute(f, a, b);
  }
};

CmpBase* make_cmp(Frame& f, Node* self, int op, Node* l, Node* r, bool ints, bool floats) {
  if (ints) {
    switch (op) {
      case CMP_LT: return respec<CmpII<CMP_LT>>(f, self, l, r);
      case CMP_LE: return respec<CmpII<CMP_LE>>(f, self, l, r);
      case CMP_GT: return respec<CmpII<CMP_GT>>(f, self, l, r);
      default: return respec<CmpII<CMP_GE>>(f, self, l, r);
    }
  }
  if (floats) {
    switch (op) {
      case CMP_LT: return respec<CmpFF<CMP_LT>>(f, self, l, r);
      case CMP_LE: return respec<CmpFF<CMP_LE>>(f, self, l, r);
      case CMP_GT: return respec<CmpFF<CMP_GT>>(f, self, l, r);
      default: return respec<CmpFF<CMP_GE>>(f, self, l, r);
    }
  }
  return respec<CmpGen>(f, self, op, l, r);
}

struct CmpUninit : CmpBase {
  using CmpBase::CmpBase;
  Value compute(Frame& f, const Value& a, const Value& b) override {
    return make_cmp(f, this, op, l_, r_, a.t == T_INT && b.t == T_INT, a.t == T_FLT && b.t == T_FLT)->compute(f, a, b);
  }
};

struct EqNode : Node {
  bool negate;
  Node *l_, *r_;
  EqNode(bool neg, Node* l, Node* r) : negate(neg), l_(l), r_(r) {
    adopt(l_);
    adopt(r_);
  }
  Value eval(Frame& f) override {
    Value a = l_->eval(f), b;
    if (a.is_gc() && !r_->is_simple()) {
      Pushed p(*f.S, a);
      b = r_->eval(f);
    } else {
      b = r_->eval(f);
    }
    bool eq;
    if (a.t == T_INT && b.t == T_INT) {
      eq = a.i == b.i;
    } else {
      f.line = line;
      eq = equals_slow(*f.S, a, b);
    }
    return Value::boolean(eq != negate);
  }
};

// ================================================================================================================
// indexing and field access
// ================================================================================================================
// Indexing t[k] where the key is computed.
struct IndexBase : Node {
  Node *obj_, *key_;
  IndexBase(Node* o, Node* k) : obj_(o), key_(k) {
    adopt(obj_);
    adopt(key_);
  }
  int target_kind() const override { return 4; }
  int node_kind() const override { return 3; }
  // What Lua's getobjname says about the value of t[k]: a small integer constant is OP_GETI ("integer index"), any other key is
  // an operand in a register and the name is "?" (a string constant never gets here, it is a FieldBase).
  void describe(std::string& out) const override {
    const ConstNode* c = dynamic_cast<const ConstNode*>(key_);
    if (c && c->v.t == T_INT && static_cast<std::uint64_t>(c->v.i) <= 255) out = "field 'integer index'";
    else if (c && c->v.t == T_STR) out = "field '" + std::string(c->v.s()->view()) + "'";
    else out = "field '?'";
  }
  Value eval(Frame& f) override {
    Value o = obj_->eval(f), k;
    if (o.is_gc() && !key_->is_simple()) {
      Pushed p(*f.S, o);
      k = key_->eval(f);
    } else {
      k = key_->eval(f);
    }
    return get(f, o, k);
  }
  // The value of o[k] once both are evaluated.
  virtual Value get(Frame& f, const Value& o, const Value& k) = 0;
  Value slow(Frame& f, const Value& o, const Value& k) {
    f.line = line;
    return index_slow(*f.S, o, k, obj_);
  }
  static Value generic_get(IndexBase* n, Frame& f, const Value& o, const Value& k) {
    if (o.t == T_TAB) {
      Value v = o.tab()->get(k);
      if (!v.is_nil() || !o.tab()->meta) return v;
    }
    return n->slow(f, o, k);
  }
};

struct IndexGen : IndexBase {
  using IndexBase::IndexBase;
  Value get(Frame& f, const Value& o, const Value& k) override { return generic_get(this, f, o, k); }
};

struct IndexArr : IndexBase {  // a table indexed by an integer
  using IndexBase::IndexBase;
  Value get(Frame& f, const Value& o, const Value& k) override {
    if (o.t == T_TAB && k.t == T_INT) {
      Table* t = o.tab();
      Value v = t->get_int(k.i);
      if (!v.is_nil() || !t->meta) return v;
      return slow(f, o, k);
    }
    ++f.S->stats.deopts;
    return respec<IndexGen>(f, this, obj_, key_)->get(f, o, k);
  }
};

struct IndexUninit : IndexBase {
  using IndexBase::IndexBase;
  Value get(Frame& f, const Value& o, const Value& k) override {
    if (o.t == T_TAB && k.t == T_INT) return respec<IndexArr>(f, this, obj_, key_)->get(f, o, k);
    return respec<IndexGen>(f, this, obj_, key_)->get(f, o, k);
  }
};

// Indexing with a constant string key: t.name. Specialized for tables (an inline cache of the node index), for host
// objects (a cache of the member by the object's class) and strings.
struct FieldBase : Node {
  Node* obj_;
  String* name_;
  FieldBase(Node* o, String* n) : obj_(o), name_(n) { adopt(obj_); }
  int target_kind() const override { return 4; }
  int node_kind() const override { return 2; }
  void describe(std::string& out) const override { out = "field '" + std::string(name_->view()) + "'"; }
  Value eval(Frame& f) override {
    Value o = obj_->eval(f);
    return get(f, o);
  }
  virtual Value get(Frame& f, const Value& o) = 0;
  Value slow(Frame& f, const Value& o) {
    f.line = line;
    return index_slow(*f.S, o, Value::str(name_), obj_);
  }
};

struct FieldGen : FieldBase {
  using FieldBase::FieldBase;
  Value get(Frame& f, const Value& o) override { return slow(f, o); }
};

struct FieldTab : FieldBase {
  long cache = -1;
  using FieldBase::FieldBase;
  Value get(Frame& f, const Value& o) override {
    if (o.t == T_TAB) {
      Table* t = o.tab();
      long i = cache;
      if (!(static_cast<unsigned long>(i) < t->hcap && t->nodes[i].key.t == T_STR && t->nodes[i].key.o == name_)) {
        i = t->find_str(name_);
        if (i >= 0) cache = i;
      }
      if (i >= 0) {
        const Value& v = t->nodes[i].val;
        if (!v.is_nil()) return v;
      }
      if (!t->meta) return Value();
      return slow(f, o);
    }
    ++f.S->stats.deopts;
    return respec<FieldGen>(f, this, obj_, name_)->get(f, o);
  }
};

struct FieldHost : FieldBase {
  const void* ic_type = nullptr;
  HostMember* ic_member = nullptr;
  using FieldBase::FieldBase;
  Value get(Frame& f, const Value& o) override {
    if (o.t == T_HOST) {
      HostObject* h = o.hostobj();
      const void* tk = h->type_key();
      if (tk != ic_type) {
        ic_member = h->member(*f.S, name_);
        ic_type = tk;
      }
      if (!ic_member) return Value();
      f.line = line;
      return ic_member->get(*f.S, h);
    }
    ++f.S->stats.deopts;
    return respec<FieldGen>(f, this, obj_, name_)->get(f, o);
  }
};

struct FieldUninit : FieldBase {
  using FieldBase::FieldBase;
  Value get(Frame& f, const Value& o) override {
    if (o.t == T_TAB) return respec<FieldTab>(f, this, obj_, name_)->get(f, o);
    if (o.t == T_HOST) return respec<FieldHost>(f, this, obj_, name_)->get(f, o);
    return respec<FieldGen>(f, this, obj_, name_)->get(f, o);
  }
};

// ---- assignment to an indexed expression ----
struct SetIndexBase : Node {
  Node *obj_, *key_, *val_;
  SetIndexBase(Node* o, Node* k, Node* v) : obj_(o), key_(k), val_(v) {
    adopt(obj_);
    adopt(key_);
    adopt(val_);
  }
  // Evaluates the object, the key and the value in that order, keeping the earlier ones rooted.
  Value eval(Frame& f) override {
    State& S = *f.S;
    Value o, k, v;
    o = obj_->eval(f);
    if (o.is_gc() && !(key_->is_simple() && val_->is_simple())) {
      Pushed po(S, o);
      k = key_->eval(f);
      if (k.is_gc() && !val_->is_simple()) {
        Pushed pk(S, k);
        v = val_->eval(f);
      } else {
        v = val_->eval(f);
      }
    } else {
      k = key_->eval(f);
      if (k.is_gc() && !val_->is_simple()) {
        Pushed pk(S, k);
        v = val_->eval(f);
      } else {
        v = val_->eval(f);
      }
    }
    put(f, o, k, v);
    return Value();
  }
  virtual void put(Frame& f, const Value& o, const Value& k, const Value& v) = 0;
  void slow(Frame& f, const Value& o, const Value& k, const Value& v) {
    f.line = line;
    setindex_slow(*f.S, o, k, v, obj_);
  }
  // A plain table: no metatable, a key that is a valid one.
  static bool plain(const Value& o, const Value& k) {
    return o.t == T_TAB && !o.tab()->meta && k.t != T_NIL && !(k.t == T_FLT && k.d != k.d);
  }
};

struct SetIndexGen : SetIndexBase {
  using SetIndexBase::SetIndexBase;
  void put(Frame& f, const Value& o, const Value& k, const Value& v) override {
    if (plain(o, k)) o.tab()->set(*f.S, k, v);
    else slow(f, o, k, v);
  }
};

struct SetIndexArr : SetIndexBase {  // a table written at an integer key
  using SetIndexBase::SetIndexBase;
  void put(Frame& f, const Value& o, const Value& k, const Value& v) override {
    if (o.t == T_TAB && k.t == T_INT && !o.tab()->meta) {
      o.tab()->set_int(*f.S, k.i, v);
      return;
    }
    ++f.S->stats.deopts;
    respec<SetIndexGen>(f, this, obj_, key_, val_)->put(f, o, k, v);
  }
};

struct SetIndexUninit : SetIndexBase {
  using SetIndexBase::SetIndexBase;
  void put(Frame& f, const Value& o, const Value& k, const Value& v) override {
    if (o.t == T_TAB && k.t == T_INT) respec<SetIndexArr>(f, this, obj_, key_, val_)->put(f, o, k, v);
    else respec<SetIndexGen>(f, this, obj_, key_, val_)->put(f, o, k, v);
  }
};

struct SetFieldBase : Node {
  Node *obj_, *val_;
  String* name_;
  SetFieldBase(Node* o, String* n, Node* v) : obj_(o), val_(v), name_(n) {
    adopt(obj_);
    adopt(val_);
  }
  Value eval(Frame& f) override {
    Value o = obj_->eval(f), v;
    if (o.is_gc() && !val_->is_simple()) {
      Pushed p(*f.S, o);
      v = val_->eval(f);
    } else {
      v = val_->eval(f);
    }
    put(f, o, v);
    return Value();
  }
  virtual void put(Frame& f, const Value& o, const Value& v) = 0;
  void slow(Frame& f, const Value& o, const Value& v) {
    f.line = line;
    setindex_slow(*f.S, o, Value::str(name_), v, obj_);
  }
};

struct SetFieldGen : SetFieldBase {
  using SetFieldBase::SetFieldBase;
  void put(Frame& f, const Value& o, const Value& v) override { slow(f, o, v); }
};

struct SetFieldTab : SetFieldBase {
  long cache = -1;
  using SetFieldBase::SetFieldBase;
  void put(Frame& f, const Value& o, const Value& v) override {
    if (o.t == T_TAB) {
      Table* t = o.tab();
      long i = cache;
      if (!(static_cast<unsigned long>(i) < t->hcap && t->nodes[i].key.t == T_STR && t->nodes[i].key.o == name_)) {
        i = t->find_str(name_);
        if (i >= 0) cache = i;
      }
      if (i >= 0 && !t->nodes[i].val.is_nil()) {  // an existing field: no metamethod can intervene
        t->nodes[i].val = v;
        t->absent = 0;
        return;
      }
      if (!t->meta) {
        t->set_str(*f.S, name_, v);
        return;
      }
      slow(f, o, v);
      return;
    }
    ++f.S->stats.deopts;
    respec<SetFieldGen>(f, this, obj_, name_, val_)->put(f, o, v);
  }
};

struct SetFieldHost : SetFieldBase {
  const void* ic_type = nullptr;
  HostMember* ic_member = nullptr;
  using SetFieldBase::SetFieldBase;
  void put(Frame& f, const Value& o, const Value& v) override {
    if (o.t == T_HOST) {
      HostObject* h = o.hostobj();
      const void* tk = h->type_key();
      if (tk != ic_type) {
        ic_member = h->member(*f.S, name_);
        ic_type = tk;
      }
      if (ic_member && !ic_member->is_method) {
        f.line = line;
        ic_member->set(*f.S, h, v);
        return;
      }
      slow(f, o, v);
      return;
    }
    ++f.S->stats.deopts;
    respec<SetFieldGen>(f, this, obj_, name_, val_)->put(f, o, v);
  }
};

struct SetFieldUninit : SetFieldBase {
  using SetFieldBase::SetFieldBase;
  void put(Frame& f, const Value& o, const Value& v) override {
    if (o.t == T_TAB) respec<SetFieldTab>(f, this, obj_, name_, val_)->put(f, o, v);
    else if (o.t == T_HOST) respec<SetFieldHost>(f, this, obj_, name_, val_)->put(f, o, v);
    else respec<SetFieldGen>(f, this, obj_, name_, val_)->put(f, o, v);
  }
};

// ================================================================================================================
// calls
// ================================================================================================================
// Evaluates the arguments onto the stack after the callee slot(s); the last one expands when it has several values.
inline int push_args(Frame& f, std::vector<Node*>& args, bool multi_last, Value* dst) {
  State& S = *f.S;
  int n = 0;
  std::size_t fixed = args.size() - (multi_last ? 1 : 0);
  check_stack(S, args.size());
  for (std::size_t i = 0; i < fixed; ++i) {
    Value v = args[i]->eval(f);
    dst[n++] = v;
    S.top = dst + n;
  }
  if (multi_last) {
    Rets tmp;
    args.back()->evalMulti(f, tmp);
    check_stack(S, static_cast<std::size_t>(tmp.n));
    for (int k = 0; k < tmp.n; ++k) dst[n++] = tmp.p[k];
    S.top = dst + n;
  }
  return n;
}

// `return f(args)` with f a script function (or an object whose __call is one): instead of calling it, the callee and its N arguments
// (at AB[1..N], the function at AB[0]) are left in the running frame, whose call_closure runs it in place of the caller. False for
// anything else (a native function, a value that cannot be called), which is called as usual.
bool tail_closure(Frame& f, Value* ab, int n) {
  State& S = *f.S;
  Value fnv = ab[0];
  if (!fnv.is_closure()) {
    if (fnv.t == T_FUN) return false;
    Value tm = tm_value(S, fnv, TM_CALL);
    if (!tm.is_closure()) return false;
    if (ab + n + 130 > S.stack_end) S.rt_error("stack overflow");
    for (int k = n; k > 0; --k) ab[k + 1] = ab[k];  // the called object becomes the first argument
    ab[1] = fnv;
    ab[0] = tm;
    ++n;
    fnv = tm;
  }
  Value* base = f.base;
  base[-1] = fnv;  // the slot that roots the running function
  for (int k = 0; k < n; ++k) base[k] = ab[1 + k];
  f.tail_cl = fnv.closure();
  f.tail_n = n;
  S.top = base + n;
  return true;
}

struct CallBase : Node {
  Node* fn_;
  std::vector<Node*> args_;
  bool multi_last_;
  CallBase(Node* fn, std::vector<Node*> args) : fn_(fn), args_(std::move(args)) {
    multi_last_ = !args_.empty() && args_.back()->is_multi();
    adopt(fn_);
    for (Node*& a : args_) adopt(a);
  }
  bool is_multi() const override { return true; }
  bool is_call() const override { return true; }
  Value eval(Frame& f) override {
    Rets r;
    run(f, r);
    return r.first();
  }
  void evalMulti(Frame& f, Rets& out) override { run(f, out); }
  int exec(Frame& f) override {
    Rets r;
    run(f, r);
    return C_NORMAL;
  }
  void run(Frame& f, Rets& out) {
    State& S = *f.S;
    Value* ab = S.top;
    check_stack(S, args_.size() + 2);
    Value fnv = fn_->eval(f);
    ab[0] = fnv;
    S.top = ab + 1;
    int n = push_args(f, args_, multi_last_, ab + 1);
    f.line = line;
    if (tail && !f.inlined && tail_closure(f, ab, n)) return;
    dispatch(f, ab[0], ab + 1, n, out);
    S.top = ab;
  }
  virtual void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) = 0;
};

struct CallGen : CallBase {
  using CallBase::CallBase;
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

// ---- inlining (nfcast_inline.inc, included at the end of this file) ----
// The number of executions of a call or method site left before it is looked at for inlining; 0 when it is switched off.
inline unsigned inline_hot(Frame& f) { return f.S->inlining ? f.S->inline_warm : 0; }
void inline_call_site(Frame& f, CallBase* site, Closure* callee);

struct CallClosure : CallBase {
  unsigned hot_ = 0;  // executions left before inline_call_site looks at this site
  using CallBase::CallBase;
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    if (fnv.t == T_FUN && fnv.o->gctype == G_CLOSURE) {
      if (hot_ && --hot_ == 0) inline_call_site(f, this, fnv.closure());
      call_closure(*f.S, fnv.closure(), args, n, out, false);
      return;
    }
    ++f.S->stats.deopts;
    respec<CallGen>(f, this, fn_, args_);
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

struct CallNative : CallBase {
  using CallBase::CallBase;
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    if (fnv.t == T_FUN && fnv.o->gctype == G_NATIVE) {
      invoke_native(*f.S, fnv.native(), args, n, out, fn_);
      return;
    }
    ++f.S->stats.deopts;
    respec<CallGen>(f, this, fn_, args_);
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

struct CallUninit : CallBase {
  using CallBase::CallBase;
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    if (fnv.is_closure()) respec<CallClosure>(f, this, fn_, args_)->hot_ = tail ? 0 : inline_hot(f);
    else if (fnv.is_native()) respec<CallNative>(f, this, fn_, args_);
    else respec<CallGen>(f, this, fn_, args_);
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

// obj:name(args). The receiver is evaluated once; the method is looked up in the receiver (a table field with an inline
// cache, the string library for a string, a member of a host object) and called with the receiver first.
struct MethodBase : Node {
  Node* obj_;
  String* name_;
  std::vector<Node*> args_;
  bool multi_last_;
  NameNode desc_;
  MethodBase(Node* o, String* n, std::vector<Node*> a)
      : obj_(o), name_(n), args_(std::move(a)), multi_last_(false), desc_("method '" + std::string(n->view()) + "'") {
    multi_last_ = !args_.empty() && args_.back()->is_multi();
    adopt(obj_);
    for (Node*& x : args_) adopt(x);
  }
  bool is_multi() const override { return true; }
  bool is_call() const override { return true; }
  Value eval(Frame& f) override {
    Rets r;
    run(f, r);
    return r.first();
  }
  void evalMulti(Frame& f, Rets& out) override { run(f, out); }
  int exec(Frame& f) override {
    Rets r;
    run(f, r);
    return C_NORMAL;
  }
  void run(Frame& f, Rets& out) { run_with(f, out, obj_->eval(f)); }
  // The call once the receiver is evaluated.
  virtual void run_with(Frame& f, Rets& out, const Value& o) = 0;

  // Common tail: ab[0] is the function, ab[1] the receiver; evaluates the arguments and calls.
  void finish(Frame& f, Value* ab, Rets& out) {
    State& S = *f.S;
    int n = push_args(f, args_, multi_last_, ab + 2);
    f.line = line;
    if (tail && !f.inlined && tail_closure(f, ab, n + 1)) return;
    call_value(S, ab[0], ab + 1, n + 1, out, &desc_);
    S.top = ab;
  }
  Value* begin(Frame& f, const Value& o) {
    State& S = *f.S;
    check_stack(S, args_.size() + 3);
    Value* ab = S.top;
    ab[0] = Value();
    ab[1] = o;
    S.top = ab + 2;
    return ab;
  }
  Value lookup_generic(Frame& f, const Value& o) {
    f.line = line;
    return index_slow(*f.S, o, Value::str(name_), obj_);
  }
  // A call of a host method: no function value is made.
  void call_host_method(Frame& f, const Value& o, Value* ab, HostMember* m, Rets& out) {
    State& S = *f.S;
    HostObject* h = o.hostobj();
    int n = push_args(f, args_, multi_last_, ab + 2);
    f.line = line;
    Args a;
    a.v = ab + 2;
    a.n = n;
    ++S.depth;
    m->call(S, h, a, out);
    --S.depth;
    S.top = ab;
  }
  // Any receiver: a host method is called directly, anything else is looked up.
  void run_generic(Frame& f, Rets& out, const Value& o) {
    Value* ab = begin(f, o);
    if (o.t == T_HOST) {
      HostMember* m = o.hostobj()->member(*f.S, name_);
      if (m && m->is_method) {
        call_host_method(f, o, ab, m, out);
        return;
      }
    }
    ab[0] = lookup_generic(f, o);
    finish(f, ab, out);
  }
};

struct MethodGen : MethodBase {
  using MethodBase::MethodBase;
  void run_with(Frame& f, Rets& out, const Value& o) override { run_generic(f, out, o); }
};

struct MethodTab;
void inline_method_site(Frame& f, MethodTab* site, Closure* callee);

struct MethodTab : MethodBase {  // the receiver is a table: its field (or an inherited one) is the method
  long cache = -1;
  unsigned hot_ = 0;  // executions left before inline_method_site looks at this site
  using MethodBase::MethodBase;
  void run_with(Frame& f, Rets& out, const Value& o) override {
    if (o.t == T_TAB) {
      Value* ab = begin(f, o);
      Table* t = o.tab();
      long i = cache;
      if (!(static_cast<unsigned long>(i) < t->hcap && t->nodes[i].key.t == T_STR && t->nodes[i].key.o == name_)) {
        i = t->find_str(name_);
        if (i >= 0) cache = i;
      }
      if (i >= 0 && !t->nodes[i].val.is_nil()) ab[0] = t->nodes[i].val;
      else ab[0] = lookup_generic(f, o);
      if (hot_ && !tail && ab[0].is_closure() && --hot_ == 0) inline_method_site(f, this, ab[0].closure());
      finish(f, ab, out);
      return;
    }
    ++f.S->stats.deopts;
    respec<MethodGen>(f, this, obj_, name_, args_)->run_with(f, out, o);
  }
};

struct MethodStr : MethodBase {  // the receiver is a string: the method comes from the string library
  long cache = -1;
  using MethodBase::MethodBase;
  void run_with(Frame& f, Rets& out, const Value& o) override {
    State& S = *f.S;
    if (o.t == T_STR && S.string_meta) {
      Value* ab = begin(f, o);
      Value idx = tm_of_table(S, S.string_meta, TM_INDEX);
      if (idx.t == T_TAB) {
        Table* lib = idx.tab();
        long i = cache;
        if (!(static_cast<unsigned long>(i) < lib->hcap && lib->nodes[i].key.t == T_STR && lib->nodes[i].key.o == name_)) {
          i = lib->find_str(name_);
          if (i >= 0) cache = i;
        }
        if (i >= 0 && !lib->nodes[i].val.is_nil()) {
          ab[0] = lib->nodes[i].val;
          finish(f, ab, out);
          return;
        }
      }
      ab[0] = lookup_generic(f, o);
      finish(f, ab, out);
      return;
    }
    ++S.stats.deopts;
    respec<MethodGen>(f, this, obj_, name_, args_)->run_with(f, out, o);
  }
};

struct MethodHost : MethodBase {  // the receiver is a host object: the member is cached by the object's class
  const void* ic_type = nullptr;
  HostMember* ic_member = nullptr;
  using MethodBase::MethodBase;
  void run_with(Frame& f, Rets& out, const Value& o) override {
    if (o.t == T_HOST) {
      Value* ab = begin(f, o);
      HostObject* h = o.hostobj();
      const void* tk = h->type_key();
      if (tk != ic_type) {
        ic_member = h->member(*f.S, name_);
        ic_type = tk;
      }
      if (ic_member && ic_member->is_method) {
        call_host_method(f, o, ab, ic_member, out);
        return;
      }
      ab[0] = lookup_generic(f, o);
      finish(f, ab, out);
      return;
    }
    ++f.S->stats.deopts;
    respec<MethodGen>(f, this, obj_, name_, args_)->run_with(f, out, o);
  }
};

struct MethodUninit : MethodBase {
  using MethodBase::MethodBase;
  void run_with(Frame& f, Rets& out, const Value& o) override {
    if (o.t == T_TAB) {
      MethodTab* m = respec<MethodTab>(f, this, obj_, name_, args_);
      m->hot_ = inline_hot(f);
      m->run_with(f, out, o);
    } else if (o.t == T_STR) respec<MethodStr>(f, this, obj_, name_, args_)->run_with(f, out, o);
    else if (o.t == T_HOST) respec<MethodHost>(f, this, obj_, name_, args_)->run_with(f, out, o);
    else respec<MethodGen>(f, this, obj_, name_, args_)->run_with(f, out, o);
  }
};

// ================================================================================================================
// table constructor
// ================================================================================================================
struct TableNode : Node {
  std::vector<TableItem> items_;
  std::uint32_t npos_ = 0, nkeyed_ = 0;
  explicit TableNode(std::vector<TableItem> items) : items_(std::move(items)) {
    for (TableItem& it : items_) {
      adopt(it.key);
      adopt(it.val);
      if (it.key) ++nkeyed_;
      else ++npos_;
    }
  }
  Value eval(Frame& f) override {
    State& S = *f.S;
    Table* t = S.new_table(npos_, nkeyed_);
    Pushed pt(S, Value::table(t));
    std::int64_t idx = 1;
    std::size_t last = items_.size();
    for (std::size_t i = 0; i < last; ++i) {
      TableItem& it = items_[i];
      if (!it.key) {
        if (i + 1 == last && it.val->is_multi()) {
          Rets r;
          it.val->evalMulti(f, r);
          for (int k = 0; k < r.n; ++k) store_pos(S, t, idx++, r.p[k]);
        } else {
          Value v = it.val->eval(f);
          store_pos(S, t, idx++, v);
        }
      } else {
        Value k = it.key->eval(f);
        Value v;
        if (k.is_gc() && !it.val->is_simple()) {
          Pushed pk(S, k);
          v = it.val->eval(f);
        } else {
          v = it.val->eval(f);
        }
        if (k.t == T_NIL) {
          f.line = line;
          S.rt_error("table index is nil");
        }
        if (k.t == T_FLT && k.d != k.d) {
          f.line = line;
          S.rt_error("table index is NaN");
        }
        t->set(S, k, v);
      }
    }
    return Value::table(t);
  }
  // A positional item goes straight into the array part, a nil included: {nil, 2} has length 2 like in Lua.
  static void store_pos(State& S, Table* t, std::int64_t idx, const Value& v) {
    std::uint32_t i = static_cast<std::uint32_t>(idx);
    t->reserve_array(S, i);
    if (i > t->asize) {
      for (std::uint32_t j = t->asize; j + 1 < i; ++j) t->arr[j] = Value();
      t->arr[i - 1] = v;
      t->asize = i;
      t->absorb(S);
    } else {
      t->arr[i - 1] = v;
    }
  }
};

// ================================================================================================================
// statements
// ================================================================================================================
struct BlockNode : Node {
  std::vector<Node*> stmts_;
  explicit BlockNode(std::vector<Node*> s) : stmts_(std::move(s)) {
    for (Node*& n : stmts_) adopt(n);
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    for (Node* s : stmts_) {
      int c = s->exec(f);
      if (c) return c;
    }
    return C_NORMAL;
  }
};

// Declares a local variable: boxes it when a closure captures it.
struct LocalSlot {
  int slot = 0;
  bool captured = false;
  VarInfo* vi = nullptr;
};

inline void declare(Frame& f, const LocalSlot& s, const Value& v) {
  if (s.captured) f.base[s.slot] = Value::object(T_CELL, new_cell(*f.S, v));
  else f.base[s.slot] = v;
}

struct LocalDeclNode : Node {
  std::vector<LocalSlot> vars_;
  std::vector<Node*> exprs_;
  bool multi_last_ = false;
  LocalDeclNode(Proto& P, std::vector<VarInfo*> vars, std::vector<Node*> exprs) : exprs_(std::move(exprs)) {
    for (VarInfo* v : vars) {
      LocalSlot s;
      s.slot = v->slot;
      s.vi = v;
      vars_.push_back(s);
    }
    multi_last_ = !exprs_.empty() && exprs_.back()->is_multi();
    for (Node*& e : exprs_) adopt(e);
    P.patchables.push_back(this);
  }
  void patch() override {
    for (LocalSlot& s : vars_) {
      s.captured = s.vi->captured;
      s.vi = nullptr;
    }
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    State& S = *f.S;
    if (vars_.size() == 1 && exprs_.size() == 1) {  // a call adjusted to one value is its first value
      Value v = exprs_[0]->eval(f);
      declare(f, vars_[0], v);
      return C_NORMAL;
    }
    if (exprs_.empty()) {
      for (const LocalSlot& s : vars_) declare(f, s, Value());
      return C_NORMAL;
    }
    // Several values: collect them on the stack (rooted), then assign.
    check_stack(S, exprs_.size() + vars_.size());
    Value* tmp = S.top;
    int n = 0;
    std::size_t fixed = exprs_.size() - (multi_last_ ? 1 : 0);
    for (std::size_t i = 0; i < fixed; ++i) {
      Value v = exprs_[i]->eval(f);
      tmp[n++] = v;
      S.top = tmp + n;
    }
    if (multi_last_) {
      Rets r;
      exprs_.back()->evalMulti(f, r);
      check_stack(S, static_cast<std::size_t>(r.n));
      for (int k = 0; k < r.n; ++k) tmp[n++] = r.p[k];
      S.top = tmp + n;
    }
    for (std::size_t i = 0; i < vars_.size(); ++i) declare(f, vars_[i], static_cast<int>(i) < n ? tmp[i] : Value());
    S.top = tmp;
    return C_NORMAL;
  }
};

// Single assignments.
struct AssignLocal : Node {
  LocalNode* target_;
  Node* val_;
  AssignLocal(LocalNode* t, Node* v) : target_(t), val_(v) { adopt(val_); }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    target_->assign(f, val_->eval(f));
    return C_NORMAL;
  }
};

struct AssignUpval : Node {
  int idx;
  Node* val_;
  AssignUpval(int i, Node* v) : idx(i), val_(v) { adopt(val_); }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    f.cl->up[idx]->v = val_->eval(f);
    return C_NORMAL;
  }
};

struct AssignGlobal : Node {
  GlobalNode* target_;
  Node* val_;
  AssignGlobal(GlobalNode* t, Node* v) : target_(t), val_(v) { adopt(val_); }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    target_->line = line;
    target_->assign(f, val_->eval(f));
    return C_NORMAL;
  }
};

// General assignment: evaluate the targets' objects and keys, then the values, then store right to left.
struct AssignMulti : Node {
  std::vector<Node*> targets_;
  std::vector<Node*> exprs_;
  bool multi_last_ = false;
  std::vector<Node*> tobj_, tkey_;  // for indexed targets (null otherwise)
  std::vector<String*> tname_;
  AssignMulti(std::vector<Node*> targets, std::vector<Node*> exprs, std::vector<Node*> tobj, std::vector<Node*> tkey,
              std::vector<String*> tname)
      : targets_(std::move(targets)), exprs_(std::move(exprs)), tobj_(std::move(tobj)), tkey_(std::move(tkey)), tname_(std::move(tname)) {
    multi_last_ = !exprs_.empty() && exprs_.back()->is_multi();
    for (Node*& e : exprs_) adopt(e);
    for (Node*& e : tobj_) adopt(e);
    for (Node*& e : tkey_) adopt(e);
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    State& S = *f.S;
    std::size_t nt = targets_.size();
    check_stack(S, nt * 3 + exprs_.size() + 4);
    Value* base = S.top;
    // slots: for target i: base[2i] object, base[2i+1] key; then the values
    for (std::size_t i = 0; i < nt; ++i) {
      if (tobj_[i]) {
        base[2 * i] = tobj_[i]->eval(f);
        S.top = base + 2 * i + 1;
        if (tkey_[i]) base[2 * i + 1] = tkey_[i]->eval(f);
        else base[2 * i + 1] = Value::str(tname_[i]);
      } else {
        base[2 * i] = Value();
        base[2 * i + 1] = Value();
      }
      S.top = base + 2 * i + 2;
    }
    Value* vals = base + 2 * nt;
    int n = 0;
    std::size_t fixed = exprs_.size() - (multi_last_ ? 1 : 0);
    for (std::size_t i = 0; i < fixed; ++i) {
      Value v = exprs_[i]->eval(f);
      vals[n++] = v;
      S.top = vals + n;
    }
    if (multi_last_) {
      Rets r;
      exprs_.back()->evalMulti(f, r);
      check_stack(S, static_cast<std::size_t>(r.n));
      for (int k = 0; k < r.n; ++k) vals[n++] = r.p[k];
      S.top = vals + n;
    }
    f.line = line;
    for (std::size_t i = nt; i > 0; --i) {
      std::size_t k = i - 1;
      Value v = static_cast<int>(k) < n ? vals[k] : Value();
      Node* t = targets_[k];
      switch (t->target_kind()) {
        case 1: static_cast<LocalNode*>(t)->assign(f, v); break;
        case 2: f.cl->up[t->upval_index()]->v = v; break;
        case 3: static_cast<GlobalNode*>(t)->assign(f, v); break;
        default: setindex_slow(S, base[2 * k], base[2 * k + 1], v, tobj_[k]); break;
      }
    }
    S.top = base;
    return C_NORMAL;
  }
};

struct WhileNode : Node {
  Node *cond_, *body_;
  WhileNode(Node* c, Node* b) : cond_(c), body_(b) {
    adopt(cond_);
    adopt(body_);
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  TierLoop* tl_ = nullptr;  // what the tier knows about this loop (nfcast_tier.cpp)
  int exec(Frame& f) override {
    TierLoopState ts;
    ts.kind = TierLoopState::WHILE;
    if (f.S->tier)
      if (int r = tier_loop(f, this, tl_, ts, false)) return r == 2 ? C_RETURN : C_NORMAL;  // compiled code takes the loop over
    while (cond_->eval(f).truthy()) {
      int c = body_->exec(f);
      if (c == C_BREAK) break;
      if (c == C_RETURN) return c;
      loop_edge(f);
      if (f.S->tier)
        if (int r = tier_loop(f, this, tl_, ts, true)) return r == 2 ? C_RETURN : C_NORMAL;
    }
    return C_NORMAL;
  }
};

struct RepeatNode : Node {
  Node *body_, *cond_;
  RepeatNode(Node* b, Node* c) : body_(b), cond_(c) {
    adopt(body_);
    adopt(cond_);
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  TierLoop* tl_ = nullptr;  // what the tier knows about this loop (nfcast_tier.cpp)
  int exec(Frame& f) override {
    TierLoopState ts;
    ts.kind = TierLoopState::REPEAT;
    if (f.S->tier)
      if (int r = tier_loop(f, this, tl_, ts, false)) return r == 2 ? C_RETURN : C_NORMAL;
    for (;;) {
      int c = body_->exec(f);
      if (c == C_BREAK) break;
      if (c == C_RETURN) return c;
      if (cond_->eval(f).truthy()) break;
      loop_edge(f);
      if (f.S->tier)
        if (int r = tier_loop(f, this, tl_, ts, true)) return r == 2 ? C_RETURN : C_NORMAL;
    }
    return C_NORMAL;
  }
};

struct IfNode : Node {
  std::vector<Node*> conds_, blocks_;
  Node* else_;
  IfNode(std::vector<Node*> c, std::vector<Node*> b, Node* e) : conds_(std::move(c)), blocks_(std::move(b)), else_(e) {
    for (Node*& n : conds_) adopt(n);
    for (Node*& n : blocks_) adopt(n);
    adopt(else_);
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    for (std::size_t i = 0; i < conds_.size(); ++i)
      if (conds_[i]->eval(f).truthy()) return blocks_[i]->exec(f);
    if (else_) return else_->exec(f);
    return C_NORMAL;
  }
};

[[noreturn]] void for_error(Frame& f, int line, const char* what, const Value& v) {
  f.line = line;
  f.S->rt_error(std::string("bad 'for' ") + what + " (number expected, got " + State::type_name(v) + ")");
}

struct NumForNode : Node {
  LocalSlot var_;
  Node *start_, *limit_, *step_, *body_;
  TierLoop* tl_ = nullptr;  // what the tier knows about this loop (nfcast_tier.cpp)
  NumForNode(Proto& P, VarInfo* v, Node* a, Node* b, Node* c, Node* body) : start_(a), limit_(b), step_(c), body_(body) {
    var_.slot = v->slot;
    var_.vi = v;
    adopt(start_);
    adopt(limit_);
    adopt(step_);
    adopt(body_);
    P.patchables.push_back(this);
  }
  void patch() override {
    var_.captured = var_.vi->captured;
    var_.vi = nullptr;
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    State& S = *f.S;
    Value init = start_->eval(f);
    Value lim = limit_->eval(f);
    Value stp = step_ ? step_->eval(f) : Value::integer(1);
    if (init.t == T_INT && stp.t == T_INT) {
      std::int64_t i0 = init.i, step = stp.i, limit;
      if (step == 0) {
        f.line = line;
        S.rt_error("'for' step is zero");
      }
      if (lim.t == T_INT) {
        limit = lim.i;
      } else if (lim.t == T_FLT) {
        if (!nfcr_forlimit(lim.d, step, &limit)) return C_NORMAL;
      } else {
        Value conv;
        if (lim.t != T_STR || !to_number(lim, &conv)) for_error(f, line, "limit", lim);
        if (conv.t == T_INT) limit = conv.i;
        else if (!nfcr_forlimit(conv.d, step, &limit)) return C_NORMAL;
      }
      if (step > 0 ? i0 > limit : i0 < limit) return C_NORMAL;
      std::uint64_t count = nfcr_forcount(i0, limit, step);  // the loop arithmetic is shared with the tier (nfcast_tier_rt.h)
      std::int64_t i = i0;
      TierLoopState ts;
      ts.kind = TierLoopState::FOR_INT;
      ts.step = step;
      if (S.tier) {
        ts.i = i;
        ts.count = count;
        if (int r = tier_loop(f, this, tl_, ts, false)) return r == 2 ? C_RETURN : C_NORMAL;  // compiled code takes the loop over
      }
      for (;;) {
        declare(f, var_, Value::integer(i));
        int c = body_->exec(f);
        if (c == C_BREAK) break;
        if (c == C_RETURN) return c;
        if (count-- == 0) break;
        i = static_cast<std::int64_t>(static_cast<std::uint64_t>(i) + static_cast<std::uint64_t>(step));
        loop_edge(f);
        if (S.tier) {
          ts.i = i;
          ts.count = count;
          if (int r = tier_loop(f, this, tl_, ts, true)) return r == 2 ? C_RETURN : C_NORMAL;
        }
      }
      return C_NORMAL;
    }
    // float loop (strings that read as numbers are converted)
    if (!init.is_number() && !(init.t == T_STR && to_number(init, &init))) for_error(f, line, "initial value", init);
    if (!lim.is_number() && !(lim.t == T_STR && to_number(lim, &lim))) for_error(f, line, "limit", lim);
    if (!stp.is_number() && !(stp.t == T_STR && to_number(stp, &stp))) for_error(f, line, "step", stp);
    double idx = num_d(init), limit = num_d(lim), step = num_d(stp);
    if (step == 0) {
      f.line = line;
      S.rt_error("'for' step is zero");
    }
    TierLoopState ts;
    ts.kind = TierLoopState::FOR_FLT;
    ts.limit = limit;
    ts.dstep = step;
    // A NaN start or limit still runs the body once here (below); compiled code tests the plain condition, so it takes over only
    // for numbers, or after an iteration (where the condition is the plain one in both).
    if (S.tier && idx == idx && limit == limit) {
      ts.d = idx;
      if (int r = tier_loop(f, this, tl_, ts, false)) return r == 2 ? C_RETURN : C_NORMAL;  // compiled code takes the loop over
    }
    // Lua's forprep skips the loop only when the start is beyond the limit; a NaN is beyond nothing, so the body runs once
    for (bool first = true; first ? !(0 < step ? limit < idx : idx < limit) : (0 < step ? idx <= limit : limit <= idx); idx += step, first = false) {
      declare(f, var_, Value::number(idx));
      int c = body_->exec(f);
      if (c == C_BREAK) break;
      if (c == C_RETURN) return c;
      loop_edge(f);
      if (S.tier) {
        ts.d = idx + step;  // where the loop goes on after this iteration
        if (int r = tier_loop(f, this, tl_, ts, true)) return r == 2 ? C_RETURN : C_NORMAL;
      }
    }
    return C_NORMAL;
  }
};

struct ForInNode : Node {
  std::vector<LocalSlot> vars_;
  std::vector<Node*> exprs_;
  int hidden_;
  Node* body_;
  bool multi_last_;
  ForInNode(Proto& P, std::vector<VarInfo*> vars, std::vector<Node*> exprs, int hidden, Node* body)
      : exprs_(std::move(exprs)), hidden_(hidden), body_(body) {
    for (VarInfo* v : vars) {
      LocalSlot s;
      s.slot = v->slot;
      s.vi = v;
      vars_.push_back(s);
    }
    multi_last_ = !exprs_.empty() && exprs_.back()->is_multi();
    for (Node*& e : exprs_) adopt(e);
    adopt(body_);
    P.patchables.push_back(this);
  }
  void patch() override {
    for (LocalSlot& s : vars_) {
      s.captured = s.vi->captured;
      s.vi = nullptr;
    }
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  void bind(Frame& f, const Value& k, const Value& v) {
    declare(f, vars_[0], k);
    if (vars_.size() > 1) {
      declare(f, vars_[1], v);
      for (std::size_t i = 2; i < vars_.size(); ++i) declare(f, vars_[i], Value());
    }
  }
  int exec(Frame& f) override {
    State& S = *f.S;
    // The three values of the explist go to the hidden slots (rooted there).
    check_stack(S, exprs_.size() + 8);
    Value* tmp = S.top;
    int n = 0;
    std::size_t fixed = exprs_.size() - (multi_last_ ? 1 : 0);
    for (std::size_t i = 0; i < fixed; ++i) {
      Value v = exprs_[i]->eval(f);
      tmp[n++] = v;
      S.top = tmp + n;
    }
    if (multi_last_) {
      Rets r;
      exprs_.back()->evalMulti(f, r);
      check_stack(S, static_cast<std::size_t>(r.n));
      for (int k = 0; k < r.n; ++k) tmp[n++] = r.p[k];
      S.top = tmp + n;
    }
    for (int k = 0; k < 3; ++k) f.base[hidden_ + k] = k < n ? tmp[k] : Value();
    S.top = tmp;
    Value fn = f.base[hidden_];
    // pairs/next over a table: walk the array part and the hash nodes with a cursor.
    if (fn.t == T_FUN && fn.o == S.next_fn && f.base[hidden_ + 1].t == T_TAB && f.base[hidden_ + 2].is_nil()) {
      Table* t = f.base[hidden_ + 1].tab();
      std::uint32_t pos = 0;
      for (;;) {
        Value key, val;
        bool found = false;
        while (pos < t->asize + t->hcap) {
          if (pos < t->asize) {
            if (!t->arr[pos].is_nil()) {
              key = Value::integer(static_cast<std::int64_t>(pos) + 1);
              val = t->arr[pos];
              found = true;
            }
          } else {
            const TNode& nd = t->nodes[pos - t->asize];
            if (!nd.val.is_nil()) {
              key = nd.key;
              val = nd.val;
              found = true;
            }
          }
          ++pos;
          if (found) break;
        }
        if (!found) break;
        bind(f, key, val);
        int c = body_->exec(f);
        if (c == C_BREAK) break;
        if (c == C_RETURN) return c;
        safepoint(S);
      }
      return C_NORMAL;
    }
    // ipairs: index 1, 2, ... until a nil
    if (fn.t == T_FUN && fn.o == S.ipairs_iter && f.base[hidden_ + 1].t == T_TAB) {
      Table* t = f.base[hidden_ + 1].tab();
      std::int64_t i = f.base[hidden_ + 2].t == T_INT ? f.base[hidden_ + 2].i : 0;
      for (;;) {
        ++i;
        Value v = t->get_int(i);
        if (v.is_nil() && t->meta) {
          f.line = line;
          v = index_slow(S, Value::table(t), Value::integer(i), nullptr);
        }
        if (v.is_nil()) break;
        bind(f, Value::integer(i), v);
        int c = body_->exec(f);
        if (c == C_BREAK) break;
        if (c == C_RETURN) return c;
        safepoint(S);
      }
      return C_NORMAL;
    }
    // any iterator: call fn(state, control) until it returns nil
    for (;;) {
      check_stack(S, 8);
      Value* ab = S.top;
      ab[0] = f.base[hidden_];
      ab[1] = f.base[hidden_ + 1];
      ab[2] = f.base[hidden_ + 2];
      S.top = ab + 3;
      Rets r;
      f.line = line;
      call_value(S, ab[0], ab + 1, 2, r, nullptr);
      S.top = ab;
      Value first = r.first();
      if (first.is_nil()) break;
      f.base[hidden_ + 2] = first;
      for (std::size_t i = 0; i < vars_.size(); ++i) declare(f, vars_[i], static_cast<int>(i) < r.n ? r.p[i] : Value());
      int c = body_->exec(f);
      if (c == C_BREAK) break;
      if (c == C_RETURN) return c;
      safepoint(S);
    }
    return C_NORMAL;
  }
};

struct LocalFuncNode : Node {
  LocalSlot var_;
  Node* fn_;
  LocalFuncNode(Proto& P, VarInfo* v, Node* fn) : fn_(fn) {
    var_.slot = v->slot;
    var_.vi = v;
    adopt(fn_);
    P.patchables.push_back(this);
  }
  void patch() override {
    var_.captured = var_.vi->captured;
    var_.vi = nullptr;
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    if (var_.captured) {
      Cell* c = new_cell(*f.S, Value());
      f.base[var_.slot] = Value::object(T_CELL, c);  // visible to the closure, which refers to itself
      c->v = fn_->eval(f);
    } else {
      f.base[var_.slot] = fn_->eval(f);
    }
    return C_NORMAL;
  }
};

struct ReturnNode : Node {
  std::vector<Node*> exprs_;
  bool multi_last_ = false;
  explicit ReturnNode(std::vector<Node*> e) : exprs_(std::move(e)) {
    multi_last_ = !exprs_.empty() && exprs_.back()->is_multi();
    for (Node*& n : exprs_) adopt(n);
    if (exprs_.size() == 1 && exprs_[0]->is_call()) exprs_[0]->tail = true;  // `return f(x)` is a tail call
  }
  Value eval(Frame& f) override {
    exec(f);
    return Value();
  }
  int exec(Frame& f) override {
    State& S = *f.S;
    if (exprs_.empty()) return C_RETURN;
    if (exprs_.size() == 1) {
      if (multi_last_) exprs_[0]->evalMulti(f, *f.rets);
      else f.rets->push(exprs_[0]->eval(f));
      return C_RETURN;
    }
    check_stack(S, exprs_.size());
    Value* tmp = S.top;
    int n = 0;
    std::size_t fixed = exprs_.size() - (multi_last_ ? 1 : 0);
    for (std::size_t i = 0; i < fixed; ++i) {
      Value v = exprs_[i]->eval(f);
      tmp[n++] = v;
      S.top = tmp + n;
    }
    Rets last;
    if (multi_last_) exprs_.back()->evalMulti(f, last);
    for (int k = 0; k < n; ++k) f.rets->push(tmp[k]);
    for (int k = 0; k < last.n; ++k) f.rets->push(last.p[k]);
    S.top = tmp;
    return C_RETURN;
  }
};

struct BreakNode : Node {
  Value eval(Frame&) override { return Value(); }
  int exec(Frame&) override { return C_BREAK; }
};

}  // namespace

#include "nfcast_tier_view.inc"  // the tier's read-only view of the node classes above

// ================================================================================================================
// factories
// ================================================================================================================
template <class N, class... A>
static N* mk(Proto& P, int line, A&&... a) {
  N* n = P.make<N>(static_cast<A&&>(a)...);
  n->line = line;
  return n;
}

Node* n_const(Proto& P, int line, const Value& v) { return mk<ConstNode>(P, line, v); }
Node* n_local(Proto& P, int line, VarInfo* vi) { return mk<LocalNode>(P, line, P, vi); }
Node* n_upval(Proto& P, int line, int idx, String* name) { return mk<UpvalNode>(P, line, idx, std::string(name->view())); }
Node* n_global(Proto& P, int line, String* name) { return mk<GlobalNode>(P, line, name); }

Node* n_index(Proto& P, int line, Node* obj, Node* key) {
  // a constant string key is a field access
  if (key->node_kind() == 1) {
    const Value& k = static_cast<ConstNode*>(key)->v;
    if (k.t == T_STR) return mk<FieldUninit>(P, line, obj, k.s());
  }
  return mk<IndexUninit>(P, line, obj, key);
}

Node* n_call(Proto& P, int line, Node* fn, std::vector<Node*> args) { return mk<CallUninit>(P, line, fn, std::move(args)); }
Node* n_method(Proto& P, int line, Node* obj, String* name, std::vector<Node*> args) {
  return mk<MethodUninit>(P, line, obj, name, std::move(args));
}
Node* n_function(Proto& P, int line, Proto* child) { return mk<FunctionNode>(P, line, child); }
Node* n_vararg(Proto& P, int line) { return mk<VarargNode>(P, line); }
Node* n_table(Proto& P, int line, std::vector<TableItem> items) { return mk<TableNode>(P, line, std::move(items)); }
Node* n_arith(Proto& P, int line, int op, Node* a, Node* b) { return mk<ArithUninit>(P, line, op, a, b); }
Node* n_unary(Proto& P, int line, int op, Node* a) { return mk<UnaryNode>(P, line, op, a); }

Node* n_compare(Proto& P, int line, int op, Node* a, Node* b) {
  if (op == CMP_EQ) return mk<EqNode>(P, line, false, a, b);
  if (op == CMP_NE) return mk<EqNode>(P, line, true, a, b);
  return mk<CmpUninit>(P, line, op, a, b);
}

Node* n_and(Proto& P, int line, Node* a, Node* b) { return mk<AndNode>(P, line, a, b); }
Node* n_or(Proto& P, int line, Node* a, Node* b) { return mk<OrNode>(P, line, a, b); }
Node* n_concat(Proto& P, int line, std::vector<Node*> parts) { return mk<ConcatNode>(P, line, std::move(parts)); }
Node* n_paren(Proto& P, int line, Node* e) {
  if (!e->is_multi()) return e;  // parentheses only matter for a call or `...` (they cut it to one value)
  return mk<ParenNode>(P, line, e);
}

Node* n_block(Proto& P, int line, std::vector<Node*> stmts) { return mk<BlockNode>(P, line, std::move(stmts)); }
Node* n_localdecl(Proto& P, int line, std::vector<VarInfo*> vars, std::vector<Node*> exprs) {
  return mk<LocalDeclNode>(P, line, P, std::move(vars), std::move(exprs));
}

Node* n_assign(Proto& P, int line, std::vector<Node*> targets, std::vector<Node*> exprs) {
  if (targets.size() == 1 && exprs.size() == 1) {
    Node* t = targets[0];
    Node* v = exprs[0];
    switch (t->target_kind()) {
      case 1: return mk<AssignLocal>(P, line, static_cast<LocalNode*>(t), v);
      case 2: return mk<AssignUpval>(P, line, t->upval_index(), v);
      case 3: return mk<AssignGlobal>(P, line, static_cast<GlobalNode*>(t), v);
      default: break;
    }
    if (t->node_kind() == 2) {
      FieldBase* fb = static_cast<FieldBase*>(t);
      return mk<SetFieldUninit>(P, line, fb->obj_, fb->name_, v);
    }
    if (t->node_kind() == 3) {
      IndexBase* ib = static_cast<IndexBase*>(t);
      return mk<SetIndexUninit>(P, line, ib->obj_, ib->key_, v);
    }
  }
  std::vector<Node*> tobj, tkey;
  std::vector<String*> tname;
  for (Node* t : targets) {
    Node* o = nullptr;
    Node* k = nullptr;
    String* nm = nullptr;
    if (t->node_kind() == 2) {
      FieldBase* fb = static_cast<FieldBase*>(t);
      o = fb->obj_;
      nm = fb->name_;
    } else if (t->node_kind() == 3) {
      IndexBase* ib = static_cast<IndexBase*>(t);
      o = ib->obj_;
      k = ib->key_;
    }
    tobj.push_back(o);
    tkey.push_back(k);
    tname.push_back(nm);
  }
  return mk<AssignMulti>(P, line, std::move(targets), std::move(exprs), std::move(tobj), std::move(tkey), std::move(tname));
}

Node* n_callstat(Proto&, int, Node* call) { return call; }
Node* n_while(Proto& P, int line, Node* cond, Node* body) { return mk<WhileNode>(P, line, cond, body); }
Node* n_repeat(Proto& P, int line, Node* body, Node* cond) { return mk<RepeatNode>(P, line, body, cond); }
Node* n_if(Proto& P, int line, std::vector<Node*> conds, std::vector<Node*> blocks, Node* els) {
  return mk<IfNode>(P, line, std::move(conds), std::move(blocks), els);
}
Node* n_fornum(Proto& P, int line, VarInfo* var, Node* start, Node* limit, Node* step, Node* body) {
  return mk<NumForNode>(P, line, P, var, start, limit, step, body);
}
Node* n_forin(Proto& P, int line, std::vector<VarInfo*> vars, std::vector<Node*> exprs, int hidden_slot, Node* body) {
  return mk<ForInNode>(P, line, P, std::move(vars), std::move(exprs), hidden_slot, body);
}
Node* n_localfunc(Proto& P, int line, VarInfo* var, Node* fn) { return mk<LocalFuncNode>(P, line, P, var, fn); }
Node* n_return(Proto& P, int line, std::vector<Node*> exprs) { return mk<ReturnNode>(P, line, std::move(exprs)); }
Node* n_break(Proto& P, int line) { return mk<BreakNode>(P, line); }

// ================================================================================================================
// inlining of small script functions
// ================================================================================================================
// Textually included: the node classes above live in an anonymous namespace.
#include "nfcast_inline.inc"

}  // namespace nfcast
