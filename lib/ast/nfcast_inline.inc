// nfcast: inlining of small script functions at the AST level (docs/notes/ast.md, "Inlining"). This file is not a translation
// unit of its own: nfcast_nodes.cpp includes it at the end, inside namespace nfcast, because it needs the node classes, which
// live in that file's anonymous namespace.
//
// A call site (`f(args)`, or `obj:m(args)` on a table) that has called the same script function a few times asks whether the
// callee is small and simple. If so, the node rewrites itself into an inlined call: it evaluates the callee expression and the
// arguments exactly as the call node did, checks that the value is a closure of the proto it was made for, and then evaluates a
// private clone of the callee's body instead of calling the function. The clone is made from the callee's tree in its
// uninitialized form (every dispatching node becomes the family's uninitialized node again), so it specializes on what this site
// sends it: a helper that sees integers at one site and floats at another has an integer tree in the first and a float tree in
// the second, where the shared tree would have given way to the generic nodes.
//
// What the inlined body runs in: a Frame of its own, on the C++ stack, linked into the interpreter's frame chain like the frame
// of a real call (State::cur), with the callee's closure, its arguments in place on the interpreter stack and its locals above
// them. That is deliberate, instead of renumbering the callee's slots into the caller's frame:
//  - a running activation of the caller has a frame of a fixed size, so slots added to the caller's Proto after it started would
//    overlap the temporaries of the evaluation in flight;
//  - everything that looks at the frame chain keeps seeing the call: the position `chunk:line:` of an error is the callee's
//    (including a callee from another chunk), `error(msg, 2)` blames the call site, a traceback has an entry for the callee
//    with its name, and the depth limit counts it;
//  - the callee's upvalues are read through its closure unchanged, so a clone is valid for every closure of the proto.
// What is saved is the call itself: no results vector, no jump through the generic dispatch, no copy of the body per
// specialization, and a body that is a single `return <expr>` is evaluated as an expression.
//
// Arguments. An argument that is a read of a local (not boxed), of an upvalue or a constant is pure, so the call does not
// evaluate it through its node: the site keeps a plan with one entry per argument (nfcast_inline.inc, ArgPlan) and copies the
// value straight into the new frame's slot. Further, when the parameter it goes to is never written by the body (and the body
// has no loop), the parameter is *substituted*: the clone reads the caller's local (SubstLocal: the frame `up` links back along
// the chain, which is the caller's frame because S.cur is the caller's while the clone runs) or holds the constant (SubstConst),
// and the slot is left nil. This is sound because a local that is not captured is written by nobody but its own function, which
// is suspended for the whole call, so reading it later gives the value the call would have copied; both nodes describe
// themselves as the callee's `local 'x'`, so the messages of errors do not change.
//
// The guard is the proto, by its `uid` (never reused, unlike an address): the clone is valid for every closure of that function,
// whatever its upvalues. A value that does not pass (another function, a native, a table with __call, nil) counts a deopt and
// rewrites the node back: into a call node that looks at the site again after a few more calls when the value is a closure (at
// most kInlineMaxRetry times per site, so a site that alternates between functions costs a bounded number of clones), else
// into the generic call node, and the site is not inlined again.
//
// Soundness notes:
//  - the clone belongs to the arena of the function that owns the site (owner_proto): it is not freed with the callee. Strings
//    its nodes refer to are added to that function's constants, which is what keeps them from the collector;
//  - a body that makes closures (a captured local would be boxed) or uses `...` is not a candidate. Neither is a vararg callee.
//    Loops (while, repeat, numeric and generic for, break) and multiple assignment are cloned like any statement: they run in
//    the frame of their own like in a real call. A node class this file does not know is refused, so a new node class is
//    never inlined by accident;
//  - recursion: a function occurs at most twice in a chain of inlined bodies (a recursive call is unrolled once), a chain has at
//    most four frames, and every inlined call counts against State::max_depth, so runaway recursion is still `stack overflow`.
namespace {

constexpr int kInlineMaxNodes = 64;   // nodes of the cloned body
constexpr int kInlineMaxSlots = 16;   // parameters and locals of the callee
constexpr int kInlineMaxNesting = 4;  // frames in a chain: the running function and the bodies inlined in it
constexpr int kInlineMaxRepeat = 2;   // times one function may occur in such a chain
constexpr unsigned kInlineMaxRetry = 3;        // times a site is inlined again after its guard failed
constexpr std::size_t kInlineMaxClones = 8192;  // nodes of clones one function takes in all (bounds what chains of clones can add)

// ---- parameter substitution -----------------------------------------------------------------------------------------------
// A read of a parameter that the call site replaced by what it was given. Both describe themselves as the parameter.
struct SubstLocal : Node {  // a local of the frame UP links back from the running one (1: the caller)
  int up, slot;
  std::string name;
  SubstLocal(int u, int s, std::string n) : up(u), slot(s), name(std::move(n)) {}
  Value eval(Frame& f) override {
    Frame* r = f.prev;
    for (int i = 1; i < up; ++i) r = r->prev;
    return r->base[slot];
  }
  bool is_simple() const override { return true; }
  void describe(std::string& out) const override { out = "local '" + name + "'"; }
};

struct SubstConst : Node {
  Value v;
  std::string name;
  SubstConst(const Value& x, std::string n) : v(x), name(std::move(n)) {}
  Value eval(Frame&) override { return v; }
  bool is_simple() const override { return true; }
  void describe(std::string& out) const override { out = "local '" + name + "'"; }
};

// The operand kind of a node for an arithmetic or comparison node (nfcast_nodes.cpp, Opnd): a local of this frame that is not
// boxed, a substituted parameter (an outer local), or a constant. Declared there; it needs the classes above.
Opnd bind_operand(Node* n) {
  Opnd o;
  if (auto* x = dynamic_cast<LocalNode*>(n)) {
    if (!x->cell) {
      o.k = Opnd::Slot;
      o.slot = x->slot;
    }
  } else if (auto* x = dynamic_cast<SubstLocal*>(n)) {
    o.k = Opnd::Outer;
    o.up = x->up;
    o.slot = x->slot;
  } else if (auto* x = dynamic_cast<ConstNode*>(n)) {
    o.k = Opnd::Const;
    o.c = x->v;
  } else if (auto* x = dynamic_cast<SubstConst*>(n)) {
    o.k = Opnd::Const;
    o.c = x->v;
  }
  return o;
}

struct ParamSub {  // what a parameter is replaced by (None: it stays in its slot)
  enum K : unsigned char { None, Local, Const } k = None;
  int up = 0, slot = 0;  // Local: the caller's local, UP frames back from the frame of the site
  Value v;               // Const
};

// ---- cloning ------------------------------------------------------------------------------------------------------------
// Copies a tree into fresh nodes in the uninitialized form. The nodes are collected here and handed to the owner's arena only
// when the whole body was accepted, so a refusal leaves nothing behind.
struct Cloner {
  std::vector<std::unique_ptr<Node>> made;
  std::vector<String*> strs;  // strings the new nodes refer to
  int budget;
  const ParamSub* sub = nullptr;  // per parameter slot, when parameters are substituted
  int nsub = 0;
  unsigned assigned = 0;          // bit per slot: written by the body (an assignment, a declaration or a loop variable)
  bool has_loop = false;
  explicit Cloner(int b) : budget(b) {}

  // The body writes slot S; it must not be a substituted parameter.
  bool writes(int s) {
    assigned |= 1u << s;
    return !(sub && s < nsub && sub[s].k != ParamSub::None);
  }
  bool writes_slots(const std::vector<LocalSlot>& v) {
    for (const LocalSlot& s : v)
      if (s.captured || !writes(s.slot)) return false;
    return true;
  }

  template <class T, class... A>
  T* make(const Node* orig, A&&... a) {
    T* c = new T(static_cast<A&&>(a)...);
    made.emplace_back(c);
    c->line = orig->line;
    return c;
  }
  template <class T>
  T* copy(T* x) {
    T* c = new T(*x);
    made.emplace_back(c);
    return c;
  }
  bool list(std::vector<Node*>& out, const std::vector<Node*>& in) {
    out.reserve(in.size());
    for (Node* x : in) {
      Node* c = clone(x);
      if (!c) return false;
      out.push_back(c);
    }
    return true;
  }
  void commit(Proto& P) {
    P.inline_nodes += made.size();
    for (std::unique_ptr<Node>& n : made) P.arena.push_back(std::move(n));
    for (String* s : strs) P.consts.push_back(s);
    made.clear();
  }

  // The clone of N, or null when N (or anything below it) cannot be inlined or the budget is gone.
  Node* clone(Node* n) {
    if (!n || --budget < 0) return nullptr;
    // ---- leaves
    if (auto* x = dynamic_cast<ConstNode*>(n)) {
      if (x->v.t == T_STR) strs.push_back(x->v.s());
      return make<ConstNode>(n, x->v);
    }
    if (auto* x = dynamic_cast<LocalNode*>(n)) {
      if (x->cell) return nullptr;
      if (sub && x->slot < nsub && sub[x->slot].k != ParamSub::None) {
        const ParamSub& p = sub[x->slot];
        if (p.k == ParamSub::Local) return make<SubstLocal>(n, p.up + 1, p.slot, x->name);
        if (p.v.t == T_STR) strs.push_back(p.v.s());
        return make<SubstConst>(n, p.v, x->name);
      }
      return copy(x);
    }
    if (auto* x = dynamic_cast<UpvalNode*>(n)) return copy(x);
    if (auto* x = dynamic_cast<GlobalNode*>(n)) {
      strs.push_back(x->name);
      GlobalNode* c = copy(x);
      c->cache = -1;
      return c;
    }
    if (auto* x = dynamic_cast<ParenNode*>(n)) {
      Node* e = clone(x->e_);
      return e ? make<ParenNode>(n, e) : nullptr;
    }
    // ---- operators: every specialization becomes the family's uninitialized node
    if (auto* x = dynamic_cast<ArithBase*>(n)) {
      Node* l = clone(x->l_);
      Node* r = l ? clone(x->r_) : nullptr;
      return r ? make<ArithUninit>(n, x->op, l, r) : nullptr;
    }
    if (auto* x = dynamic_cast<UnaryNode*>(n)) {
      Node* e = clone(x->e_);
      return e ? make<UnaryNode>(n, x->op, e) : nullptr;
    }
    if (auto* x = dynamic_cast<AndNode*>(n)) {
      Node* l = clone(x->l_);
      Node* r = l ? clone(x->r_) : nullptr;
      return r ? make<AndNode>(n, l, r) : nullptr;
    }
    if (auto* x = dynamic_cast<OrNode*>(n)) {
      Node* l = clone(x->l_);
      Node* r = l ? clone(x->r_) : nullptr;
      return r ? make<OrNode>(n, l, r) : nullptr;
    }
    if (auto* x = dynamic_cast<ConcatNode*>(n)) {
      std::vector<Node*> parts;
      return list(parts, x->parts_) ? make<ConcatNode>(n, std::move(parts)) : nullptr;
    }
    if (auto* x = dynamic_cast<CmpBase*>(n)) {
      Node* l = clone(x->l_);
      Node* r = l ? clone(x->r_) : nullptr;
      return r ? make<CmpUninit>(n, x->op, l, r) : nullptr;
    }
    if (auto* x = dynamic_cast<EqNode*>(n)) {
      Node* l = clone(x->l_);
      Node* r = l ? clone(x->r_) : nullptr;
      return r ? make<EqNode>(n, x->negate, l, r) : nullptr;
    }
    // ---- indexing
    if (auto* x = dynamic_cast<IndexBase*>(n)) {
      Node* o = clone(x->obj_);
      Node* k = o ? clone(x->key_) : nullptr;
      return k ? make<IndexUninit>(n, o, k) : nullptr;
    }
    if (auto* x = dynamic_cast<FieldBase*>(n)) {
      Node* o = clone(x->obj_);
      if (!o) return nullptr;
      strs.push_back(x->name_);
      return make<FieldUninit>(n, o, x->name_);
    }
    if (auto* x = dynamic_cast<SetIndexBase*>(n)) {
      Node* o = clone(x->obj_);
      Node* k = o ? clone(x->key_) : nullptr;
      Node* v = k ? clone(x->val_) : nullptr;
      return v ? make<SetIndexUninit>(n, o, k, v) : nullptr;
    }
    if (auto* x = dynamic_cast<SetFieldBase*>(n)) {
      Node* o = clone(x->obj_);
      Node* v = o ? clone(x->val_) : nullptr;
      if (!v) return nullptr;
      strs.push_back(x->name_);
      return make<SetFieldUninit>(n, o, x->name_, v);
    }
    // ---- calls: whatever a call node of the callee has become (an inlined call included) is a fresh uninitialized call
    if (auto* x = dynamic_cast<CallBase*>(n)) {
      Node* fn = clone(x->fn_);
      std::vector<Node*> args;
      return (fn && list(args, x->args_)) ? make<CallUninit>(n, fn, std::move(args)) : nullptr;
    }
    if (auto* x = dynamic_cast<MethodBase*>(n)) {
      Node* o = clone(x->obj_);
      std::vector<Node*> args;
      if (!o || !list(args, x->args_)) return nullptr;
      strs.push_back(x->name_);
      return make<MethodUninit>(n, o, x->name_, std::move(args));
    }
    if (auto* x = dynamic_cast<TableNode*>(n)) {
      std::vector<TableItem> items;
      for (const TableItem& it : x->items_) {
        TableItem c{nullptr, nullptr};
        if (it.key && !(c.key = clone(it.key))) return nullptr;
        if (!(c.val = clone(it.val))) return nullptr;
        items.push_back(c);
      }
      return make<TableNode>(n, std::move(items));
    }
    // ---- statements
    if (auto* x = dynamic_cast<BlockNode*>(n)) {
      std::vector<Node*> stmts;
      return list(stmts, x->stmts_) ? make<BlockNode>(n, std::move(stmts)) : nullptr;
    }
    if (auto* x = dynamic_cast<LocalDeclNode*>(n)) {
      if (!writes_slots(x->vars_)) return nullptr;
      LocalDeclNode* c = copy(x);
      for (std::size_t i = 0; i < c->exprs_.size(); ++i) {
        c->exprs_[i] = clone(x->exprs_[i]);
        if (!c->exprs_[i]) return nullptr;
        c->adopt(c->exprs_[i]);
      }
      return c;
    }
    if (auto* x = dynamic_cast<AssignLocal*>(n)) {
      if (x->target_->cell || !writes(x->target_->slot)) return nullptr;
      Node* t = clone(x->target_);
      Node* v = t ? clone(x->val_) : nullptr;
      return v ? make<AssignLocal>(n, static_cast<LocalNode*>(t), v) : nullptr;
    }
    if (auto* x = dynamic_cast<AssignUpval*>(n)) {
      Node* v = clone(x->val_);
      return v ? make<AssignUpval>(n, x->idx, v) : nullptr;
    }
    if (auto* x = dynamic_cast<AssignGlobal*>(n)) {
      Node* t = clone(x->target_);
      Node* v = t ? clone(x->val_) : nullptr;
      return v ? make<AssignGlobal>(n, static_cast<GlobalNode*>(t), v) : nullptr;
    }
    if (auto* x = dynamic_cast<IfNode*>(n)) {
      std::vector<Node*> conds, blocks;
      Node* els = nullptr;
      if (!list(conds, x->conds_) || !list(blocks, x->blocks_)) return nullptr;
      if (x->else_ && !(els = clone(x->else_))) return nullptr;
      return make<IfNode>(n, std::move(conds), std::move(blocks), els);
    }
    if (auto* x = dynamic_cast<ReturnNode*>(n)) {
      if (x->exprs_.size() == 1 && x->exprs_[0]->is_call()) return nullptr;  // a tail call replaces its frame, which a clone cannot
      std::vector<Node*> exprs;
      return list(exprs, x->exprs_) ? make<ReturnNode>(n, std::move(exprs)) : nullptr;
    }
    // ---- loops and multiple assignment
    if (auto* x = dynamic_cast<AssignMulti*>(n)) {
      std::vector<Node*> targets, exprs, tobj, tkey;
      if (!list(exprs, x->exprs_)) return nullptr;
      for (std::size_t i = 0; i < x->targets_.size(); ++i) {
        Node* t = x->targets_[i];
        Node *o = nullptr, *k = nullptr, *tc = nullptr;
        if (x->tobj_[i]) {  // indexed: the target node is only a shape, its parts are tobj_ / tkey_ (shared, as the parser does)
          if (!(o = clone(x->tobj_[i]))) return nullptr;
          if (x->tkey_[i] && !(k = clone(x->tkey_[i]))) return nullptr;
          if (x->tname_[i]) {
            strs.push_back(x->tname_[i]);
            tc = make<FieldUninit>(t, o, x->tname_[i]);
          } else {
            tc = make<IndexUninit>(t, o, k);
          }
        } else if (auto* l = dynamic_cast<LocalNode*>(t)) {
          if (l->cell || !writes(l->slot)) return nullptr;
          tc = copy(l);
        } else if (auto* u = dynamic_cast<UpvalNode*>(t)) {
          tc = copy(u);
        } else if (auto* g = dynamic_cast<GlobalNode*>(t)) {
          strs.push_back(g->name);
          GlobalNode* gc = copy(g);
          gc->cache = -1;
          tc = gc;
        } else {
          return nullptr;
        }
        targets.push_back(tc);
        tobj.push_back(o);
        tkey.push_back(k);
      }
      return make<AssignMulti>(n, std::move(targets), std::move(exprs), std::move(tobj), std::move(tkey), x->tname_);
    }
    if (auto* x = dynamic_cast<WhileNode*>(n)) {
      has_loop = true;
      Node* c = clone(x->cond_);
      Node* b = c ? clone(x->body_) : nullptr;
      return b ? make<WhileNode>(n, c, b) : nullptr;
    }
    if (auto* x = dynamic_cast<RepeatNode*>(n)) {
      has_loop = true;
      Node* b = clone(x->body_);
      Node* c = b ? clone(x->cond_) : nullptr;
      return c ? make<RepeatNode>(n, b, c) : nullptr;
    }
    if (auto* x = dynamic_cast<NumForNode*>(n)) {
      has_loop = true;
      if (x->var_.captured || !writes(x->var_.slot)) return nullptr;
      NumForNode* c = copy(x);
      c->start_ = clone(x->start_);
      c->limit_ = c->start_ ? clone(x->limit_) : nullptr;
      c->step_ = x->step_ ? clone(x->step_) : nullptr;
      c->body_ = c->limit_ ? clone(x->body_) : nullptr;
      if (!c->start_ || !c->limit_ || !c->body_ || (x->step_ && !c->step_)) return nullptr;
      c->adopt(c->start_);
      c->adopt(c->limit_);
      c->adopt(c->step_);
      c->adopt(c->body_);
      return c;
    }
    if (auto* x = dynamic_cast<ForInNode*>(n)) {
      has_loop = true;
      if (!writes_slots(x->vars_)) return nullptr;
      ForInNode* c = copy(x);
      if (!list(c->exprs_ = {}, x->exprs_) || !(c->body_ = clone(x->body_))) return nullptr;
      for (Node*& e : c->exprs_) c->adopt(e);
      c->adopt(c->body_);
      return c;
    }
    if (dynamic_cast<BreakNode*>(n)) return make<BreakNode>(n);
    // Not inlined: `...`, function expressions and local functions (closures), and any node class this list does not know.
    return nullptr;
  }
};

// ---- the inlined body and its frame ---------------------------------------------------------------------------------------
// What the frame of a call is, for a body that has no varargs and no boxed parameters: call_closure without the parts that do
// not apply, and with the frame flagged `inlined`.
struct InlinedFrame {
  State& S;
  Frame fr;
  InlinedFrame(Frame& caller, Closure* cl, Value* args, int n, Rets* rets) : S(*caller.S) {
    Proto* p = cl->proto;
    if (S.depth >= S.max_depth) S.rt_error("stack overflow");
    int nslots = p->nslots, np = p->nparams;
    if (args + nslots + 128 > S.stack_end) S.rt_error("stack overflow");
    for (int k = n < np ? n : np; k < nslots; ++k) args[k] = Value();
    S.top = args + nslots;
    fr.S = &S;
    fr.cl = cl;
    fr.base = args;
    fr.va = nullptr;
    fr.nva = 0;
    fr.rets = rets;
    fr.prev = S.cur;
    fr.native_below = false;
    fr.inlined = true;
    fr.line = p->linedefined;
    S.cur = &fr;
    ++S.depth;
    ++S.stats.inlined_calls;
    safepoint(S);
  }
  void leave() {
    S.cur = fr.prev;
    --S.depth;
  }
};

struct InlineBody {
  std::uint64_t uid = 0;  // the proto this body was cloned from
  Node* expr = nullptr;   // the body is `return <expr>`: this is the clone of <expr>
  Node* body = nullptr;   // else the clone of the whole block

  bool matches(const Value& v) const { return v.t == T_FUN && v.o->gctype == G_CLOSURE && v.closure()->proto->uid == uid; }

  // The results of calling CL (a closure of the proto) with the N arguments at ARGS, which sit on the interpreter stack.
  void multi(Frame& caller, Closure* cl, Value* args, int n, Rets& out) {
    InlinedFrame in(caller, cl, args, n, &out);
    if (expr) expr->evalMulti(in.fr, out);
    else body->exec(in.fr);
    in.leave();
  }
  // The first result only.
  Value value(Frame& caller, Closure* cl, Value* args, int n) {
    if (expr) {
      InlinedFrame in(caller, cl, args, n, nullptr);
      Value r = expr->eval(in.fr);
      in.leave();
      return r;
    }
    Rets r;
    multi(caller, cl, args, n, r);
    return r.first();
  }
};

// ---- arguments -------------------------------------------------------------------------------------------------------------
// How one argument (or the callee expression) is put in place. Anything but Eval is pure: it reads a local that is not boxed, an
// upvalue or a constant, which runs no script code and allocates nothing.
struct ArgPlan {
  enum K : unsigned char { Eval, Local, Upval, Const } k = Eval;
  bool subst = false;  // the clone reads the source itself: the slot stays nil (restore_args puts the value there when needed)
  bool skip = false;   // an extra argument (beyond the parameters) that is pure: not even stored (restore_args, likewise)
  int up = 0;  // Local: frames back from the running one (0: its own)
  int idx = 0; // Local: the slot; Upval: the index
  Value v;     // Const
};

inline ArgPlan classify(Node* a) {
  ArgPlan p;
  if (auto* x = dynamic_cast<LocalNode*>(a)) {
    if (!x->cell) {
      p.k = ArgPlan::Local;
      p.idx = x->slot;
    }
  } else if (auto* x = dynamic_cast<SubstLocal*>(a)) {
    p.k = ArgPlan::Local;
    p.up = x->up;
    p.idx = x->slot;
  } else if (auto* x = dynamic_cast<UpvalNode*>(a)) {
    p.k = ArgPlan::Upval;
    p.idx = x->idx;
  } else if (auto* x = dynamic_cast<ConstNode*>(a)) {
    p.k = ArgPlan::Const;
    p.v = x->v;
  } else if (auto* x = dynamic_cast<SubstConst*>(a)) {
    p.k = ArgPlan::Const;
    p.v = x->v;
  }
  return p;
}

inline Value plan_read(Frame& f, const ArgPlan& p) {
  switch (p.k) {
    case ArgPlan::Local: {
      Frame* r = &f;
      for (int i = p.up; i > 0; --i) r = r->prev;
      return r->base[p.idx];
    }
    case ArgPlan::Upval: return f.cl->up[p.idx]->v;
    default: return p.v;
  }
}

// Evaluates the arguments ARGS into A[0..] like push_args, but as PLAN says when there is one (it has an entry per argument; it
// is empty when the last argument expands to several values). Returns the number of arguments.
inline int place_args(Frame& f, std::vector<Node*>& args, bool multi_last, const std::vector<ArgPlan>& plan, Value* a) {
  if (multi_last) return push_args(f, args, multi_last, a);
  State& S = *f.S;
  std::size_t n = args.size();
  for (std::size_t i = 0; i < n; ++i) {
    const ArgPlan& p = plan[i];
    if (p.subst) {
      a[i] = Value();
    } else {
      switch (p.k) {
        case ArgPlan::Eval: a[i] = args[i]->eval(f); break;
        default:
          if (p.skip) continue;
          a[i] = plan_read(f, p);
          break;
      }
    }
    S.top = a + i + 1;  // rooted from here on (an upvalue read may be overwritten by a later argument)
  }
  return static_cast<int>(n);
}

// The guard failed, so another function runs for real and reads its parameters from their slots: the arguments that were
// substituted or not stored at all (extra ones) get their values, which are still where they were read from.
inline void restore_args(Frame& f, const std::vector<ArgPlan>& plan, Value* a) {
  for (std::size_t i = 0; i < plan.size(); ++i)
    if (plan[i].subst || plan[i].skip) a[i] = plan_read(f, plan[i]);
}

// f(args) where f has been a closure of one proto.
struct InlineCall : CallBase {
  InlineBody ib;
  std::vector<ArgPlan> plan;
  ArgPlan fnp;
  unsigned retry_ = 0;  // how often this site gave up an inlined version after a guard failure
  InlineCall(Node* fn, std::vector<Node*> args, const InlineBody& b, std::vector<ArgPlan> pl, const ArgPlan& fp, unsigned retry)
      : CallBase(fn, std::move(args)), ib(b), plan(std::move(pl)), fnp(fp), retry_(retry) {
    adopt(ib.expr);
    adopt(ib.body);
  }
  // The callee expression, then the arguments, in place; returns the number of arguments.
  int prepare(Frame& f, Value*& ab) {
    State& S = *f.S;
    ab = S.top;
    check_stack(S, args_.size() + 2);
    ab[0] = fnp.k == ArgPlan::Eval ? fn_->eval(f) : plan_read(f, fnp);
    S.top = ab + 1;
    int n = place_args(f, args_, multi_last_, plan, ab + 1);
    f.line = line;
    return n;
  }
  Value eval(Frame& f) override {
    Value* ab;
    int n = prepare(f, ab);
    Value r;
    if (ib.matches(ab[0])) {
      r = ib.value(f, ab[0].closure(), ab + 1, n);
    } else {
      Rets rr;
      miss(f, ab[0], ab + 1, n, rr);
      r = rr.first();
    }
    f.S->top = ab;
    return r;
  }
  void evalMulti(Frame& f, Rets& out) override {
    Value* ab;
    int n = prepare(f, ab);
    dispatch(f, ab[0], ab + 1, n, out);
    f.S->top = ab;
  }
  int exec(Frame& f) override {
    eval(f);
    return C_NORMAL;
  }
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    if (ib.matches(fnv)) ib.multi(f, fnv.closure(), args, n, out);
    else miss(f, fnv, args, n, out);
  }
  // The guard failed (a closure of another proto, a native, a __call object, nil): the site is a plain call node again, which
  // looks at it for inlining once more when the value is a closure (a few times at most), else the generic call node.
  void miss(Frame& f, const Value& fnv, Value* args, int n, Rets& out) {
    ++f.S->stats.deopts;
    restore_args(f, plan, args);
    unsigned hot = inline_hot(f);
    if (hot && retry_ < kInlineMaxRetry && fnv.is_closure()) {
      CallClosure* c = respec<CallClosure>(f, this, fn_, args_);
      c->hot_ = hot;
      c->retry_ = retry_ + 1;
    } else {
      respec<CallGen>(f, this, fn_, args_);
    }
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

// obj:name(args) where obj is a table and the method has been a closure of one proto.
struct MethodInline : MethodBase {
  long cache = -1;
  InlineBody ib;
  std::vector<ArgPlan> plan;
  unsigned retry_ = 0;  // how often this site gave up an inlined version after a guard failure
  MethodInline(Node* o, String* n, std::vector<Node*> a, const InlineBody& b, std::vector<ArgPlan> pl, unsigned retry)
      : MethodBase(o, n, std::move(a)), ib(b), plan(std::move(pl)), retry_(retry) {
    adopt(ib.expr);
    adopt(ib.body);
  }
  // Looks the method up in the table O and evaluates the arguments: ab[0] the method, ab[1] the receiver, then the arguments;
  // returns their number (without the receiver).
  int prepare(Frame& f, const Value& o, Value*& ab) {
    ab = begin(f, o);
    Table* t = o.tab();
    long i = cache;
    if (!(static_cast<unsigned long>(i) < t->hcap && t->nodes[i].key.t == T_STR && t->nodes[i].key.o == name_)) {
      i = t->find_str(name_);
      if (i >= 0) cache = i;
    }
    if (i >= 0 && !t->nodes[i].val.is_nil()) ab[0] = t->nodes[i].val;
    else ab[0] = lookup_generic(f, o);
    int n = place_args(f, args_, multi_last_, plan, ab + 2);
    f.line = line;
    return n;
  }
  void run_with(Frame& f, Rets& out, const Value& o) override {
    if (o.t != T_TAB) {
      ++f.S->stats.deopts;
      respec<MethodGen>(f, this, obj_, name_, args_)->run_with(f, out, o);
      return;
    }
    Value* ab;
    int n = prepare(f, o, ab);
    if (ib.matches(ab[0])) ib.multi(f, ab[0].closure(), ab + 1, n + 1, out);
    else miss(f, ab, n, out);
    f.S->top = ab;
  }
  Value eval(Frame& f) override {
    Value o = obj_->eval(f);
    Value r;
    if (o.t != T_TAB) {
      Rets rr;
      run_with(f, rr, o);
      return rr.first();
    }
    Value* ab;
    int n = prepare(f, o, ab);
    if (ib.matches(ab[0])) {
      r = ib.value(f, ab[0].closure(), ab + 1, n + 1);
    } else {
      Rets rr;
      miss(f, ab, n, rr);
      r = rr.first();
    }
    f.S->top = ab;
    return r;
  }
  void miss(Frame& f, Value* ab, int n, Rets& out) {
    ++f.S->stats.deopts;
    restore_args(f, plan, ab + 2);
    MethodTab* m = respec<MethodTab>(f, this, obj_, name_, args_);  // hot_ stays 0 unless the site gets another chance
    unsigned hot = inline_hot(f);
    if (hot && retry_ < kInlineMaxRetry && ab[0].is_closure()) {
      m->hot_ = hot;
      m->retry_ = retry_ + 1;
    }
    call_value(*f.S, ab[0], ab + 1, n + 1, out, &desc_);
  }
};

// Clones the block B into IB (the single `return <expr>` form is cloned as the expression).
bool clone_body(Cloner& cl, BlockNode* b, InlineBody* ib) {
  ReturnNode* r = b->stmts_.size() == 1 ? dynamic_cast<ReturnNode*>(b->stmts_[0]) : nullptr;
  ib->expr = ib->body = nullptr;
  if (r && r->exprs_.size() == 1 && !r->exprs_[0]->is_call()) ib->expr = cl.clone(r->exprs_[0]);  // `return f(x)` is a tail call: the body form refuses it
  else ib->body = cl.clone(b);
  return ib->expr || ib->body;
}

// The arguments of a site as the plan puts them, and what of them the clone substitutes.
struct SiteArgs {
  std::vector<Node*>& args;
  bool multi_last;
  int first_param;  // 0 for f(args); 1 for obj:m(args), where the receiver is parameter 0
  std::vector<ArgPlan> plan;
  SiteArgs(std::vector<Node*>& a, bool m, int fp) : args(a), multi_last(m), first_param(fp) {}
};

// Builds the body CP would have if inlined at a site whose running frame is F; false when CP is not a candidate.
bool inline_body(Frame& f, Proto* cp, Cloner& cl, InlineBody* ib, SiteArgs& sa) {
  if (cp->vararg || !cp->captured_params.empty() || cp->nslots > kInlineMaxSlots || !cp->body) return false;
  if (owner_proto(f)->inline_nodes > kInlineMaxClones) return false;
  int depth = 0, same = 0;
  for (Frame* r = &f;; r = r->prev) {
    ++depth;
    if (r->cl->proto == cp) ++same;
    if (!r->inlined) break;
  }
  if (depth >= kInlineMaxNesting || same >= kInlineMaxRepeat) return false;
  BlockNode* b = dynamic_cast<BlockNode*>(cp->body);
  if (!b) return false;
  ib->uid = cp->uid;
  // With the tier on, a callee with a loop is a candidate for native code, which a clone (always interpreted, and not counted as
  // a call) would keep it from: such a call is left to the tier.
  auto finish = [&] { return clone_body(cl, b, ib) && !(cl.has_loop && f.S->tier); };
  if (sa.multi_last) return finish();  // an expanding last argument: every argument goes through its slot
  int np = cp->nparams;
  std::size_t na = sa.args.size();
  sa.plan.resize(na);
  bool any = false;
  for (std::size_t i = 0; i < na; ++i) {
    sa.plan[i] = classify(sa.args[i]);
    any = any || sa.plan[i].k == ArgPlan::Local || sa.plan[i].k == ArgPlan::Const;
  }
  ParamSub subs[kInlineMaxSlots];
  if (any) {
    // A first clone, only to learn which parameters the body writes and whether it loops; substituting the others needs both.
    Cloner dry(kInlineMaxNodes);
    InlineBody scratch;
    if (!clone_body(dry, b, &scratch)) return false;
    if (!dry.has_loop) {
      for (std::size_t i = 0; i < na; ++i) {
        int prm = static_cast<int>(i) + sa.first_param;
        ArgPlan& p = sa.plan[i];
        if (prm >= np || (dry.assigned >> prm & 1u)) continue;
        if (p.k == ArgPlan::Local) {
          subs[prm].k = ParamSub::Local;
          subs[prm].up = p.up;
          subs[prm].slot = p.idx;
        } else if (p.k == ArgPlan::Const) {
          subs[prm].k = ParamSub::Const;
          subs[prm].v = p.v;
        } else {
          continue;
        }
        p.subst = true;
      }
      cl.sub = subs;
      cl.nsub = np < kInlineMaxSlots ? np : kInlineMaxSlots;
    }
  }
  // Pure extra arguments (beyond the parameters) are not even evaluated.
  for (std::size_t i = 0; i < na; ++i)
    if (static_cast<int>(i) + sa.first_param >= np && sa.plan[i].k != ArgPlan::Eval) sa.plan[i].skip = true;
  return finish();
}

void inline_call_site(Frame& f, CallBase* site, Closure* callee, unsigned retry) {
  State& S = *f.S;
  if (!S.inlining) return;
  Cloner cl(kInlineMaxNodes);
  InlineBody ib;
  SiteArgs sa(site->args_, site->multi_last_, 0);
  if (!inline_body(f, callee->proto, cl, &ib, sa)) {
    ++S.stats.inline_declined;
    return;
  }
  Proto* P = owner_proto(f);
  cl.commit(*P);
  for (const ArgPlan& p : sa.plan) S.stats.inline_substituted += p.subst;
  InlineCall* neu = P->make<InlineCall>(site->fn_, site->args_, ib, std::move(sa.plan), classify(site->fn_), retry);
  site->rewire(neu);
  ++S.stats.rewrites;
  ++S.stats.inlined_sites;
}

void inline_method_site(Frame& f, MethodTab* site, Closure* callee, unsigned retry) {
  State& S = *f.S;
  if (!S.inlining) return;
  Cloner cl(kInlineMaxNodes);
  InlineBody ib;
  SiteArgs sa(site->args_, site->multi_last_, 1);
  if (!inline_body(f, callee->proto, cl, &ib, sa)) {
    ++S.stats.inline_declined;
    return;
  }
  Proto* P = owner_proto(f);
  cl.commit(*P);
  for (const ArgPlan& p : sa.plan) S.stats.inline_substituted += p.subst;
  MethodInline* neu = P->make<MethodInline>(site->obj_, site->name_, site->args_, ib, std::move(sa.plan), retry);
  neu->cache = site->cache;
  site->rewire(neu);
  ++S.stats.rewrites;
  ++S.stats.inlined_sites;
}

}  // namespace
