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
// The guard is the proto, by its `uid` (never reused, unlike an address): the clone is valid for every closure of that function,
// whatever its upvalues. A value that does not pass (another function, a native, a table with __call, nil) rewrites the node
// back into the generic call node, counts a deopt, and the site is not inlined again.
//
// Soundness notes:
//  - the clone belongs to the arena of the function that owns the site (owner_proto): it is not freed with the callee. Strings
//    its nodes refer to are added to that function's constants, which is what keeps them from the collector;
//  - a body that makes closures (a captured local would be boxed), uses `...`, has loops, or assigns several targets at once is
//    not a candidate. Neither is a vararg callee. A node class this file does not know is refused, so a new node class is
//    never inlined by accident;
//  - recursion: a function occurs at most twice in a chain of inlined bodies (a recursive call is unrolled once), a chain has at
//    most four frames, and every inlined call counts against State::max_depth, so runaway recursion is still `stack overflow`.
namespace {

constexpr int kInlineMaxNodes = 64;   // nodes of the cloned body
constexpr int kInlineMaxSlots = 16;   // parameters and locals of the callee
constexpr int kInlineMaxNesting = 4;  // frames in a chain: the running function and the bodies inlined in it
constexpr int kInlineMaxRepeat = 2;   // times one function may occur in such a chain
constexpr std::size_t kInlineMaxClones = 8192;  // nodes of clones one function takes in all (bounds what chains of clones can add)

// ---- cloning ------------------------------------------------------------------------------------------------------------
// Copies a tree into fresh nodes in the uninitialized form. The nodes are collected here and handed to the owner's arena only
// when the whole body was accepted, so a refusal leaves nothing behind.
struct Cloner {
  std::vector<std::unique_ptr<Node>> made;
  std::vector<String*> strs;  // strings the new nodes refer to
  int budget;
  explicit Cloner(int b) : budget(b) {}

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
    if (auto* x = dynamic_cast<LocalNode*>(n)) return x->cell ? nullptr : copy(x);
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
      for (const LocalSlot& s : x->vars_)
        if (s.captured) return nullptr;
      LocalDeclNode* c = copy(x);
      for (std::size_t i = 0; i < c->exprs_.size(); ++i) {
        c->exprs_[i] = clone(x->exprs_[i]);
        if (!c->exprs_[i]) return nullptr;
        c->adopt(c->exprs_[i]);
      }
      return c;
    }
    if (auto* x = dynamic_cast<AssignLocal*>(n)) {
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
    // Not inlined: `...`, function expressions and local functions (closures), loops and break, multiple assignment, and any
    // node class this list does not know.
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

// f(args) where f has been a closure of one proto.
struct InlineCall : CallBase {
  InlineBody ib;
  InlineCall(Node* fn, std::vector<Node*> args, const InlineBody& b) : CallBase(fn, std::move(args)), ib(b) {
    adopt(ib.expr);
    adopt(ib.body);
  }
  Value eval(Frame& f) override {
    State& S = *f.S;
    Value* ab = S.top;
    check_stack(S, args_.size() + 2);
    ab[0] = fn_->eval(f);
    S.top = ab + 1;
    int n = push_args(f, args_, multi_last_, ab + 1);
    f.line = line;
    Value r;
    if (ib.matches(ab[0])) {
      r = ib.value(f, ab[0].closure(), ab + 1, n);
    } else {
      Rets rr;
      miss(f, ab[0], ab + 1, n, rr);
      r = rr.first();
    }
    S.top = ab;
    return r;
  }
  void dispatch(Frame& f, const Value& fnv, Value* args, int n, Rets& out) override {
    if (ib.matches(fnv)) ib.multi(f, fnv.closure(), args, n, out);
    else miss(f, fnv, args, n, out);
  }
  // The guard failed: back to the generic call node (a closure of another proto, a native, a __call object, nil).
  void miss(Frame& f, const Value& fnv, Value* args, int n, Rets& out) {
    ++f.S->stats.deopts;
    respec<CallGen>(f, this, fn_, args_);
    call_value(*f.S, fnv, args, n, out, fn_);
  }
};

// obj:name(args) where obj is a table and the method has been a closure of one proto.
struct MethodInline : MethodBase {
  long cache = -1;
  InlineBody ib;
  MethodInline(Node* o, String* n, std::vector<Node*> a, const InlineBody& b) : MethodBase(o, n, std::move(a)), ib(b) {
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
    int n = push_args(f, args_, multi_last_, ab + 2);
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
    respec<MethodTab>(f, this, obj_, name_, args_);  // hot_ stays 0: this site is not inlined again
    call_value(*f.S, ab[0], ab + 1, n + 1, out, &desc_);
  }
};

// Builds the body CP would have if inlined at a site whose running frame is F; false when CP is not a candidate.
bool inline_body(Frame& f, Proto* cp, Cloner& cl, InlineBody* ib) {
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
  ReturnNode* r = b->stmts_.size() == 1 ? dynamic_cast<ReturnNode*>(b->stmts_[0]) : nullptr;
  if (r && r->exprs_.size() == 1 && !r->exprs_[0]->is_call()) ib->expr = cl.clone(r->exprs_[0]);
  else ib->body = cl.clone(b);
  ib->uid = cp->uid;
  return ib->expr || ib->body;
}

void inline_call_site(Frame& f, CallBase* site, Closure* callee) {
  State& S = *f.S;
  if (!S.inlining) return;
  Cloner cl(kInlineMaxNodes);
  InlineBody ib;
  if (!inline_body(f, callee->proto, cl, &ib)) {
    ++S.stats.inline_declined;
    return;
  }
  Proto* P = owner_proto(f);
  cl.commit(*P);
  InlineCall* neu = P->make<InlineCall>(site->fn_, site->args_, ib);
  site->rewire(neu);
  ++S.stats.rewrites;
  ++S.stats.inlined_sites;
}

void inline_method_site(Frame& f, MethodTab* site, Closure* callee) {
  State& S = *f.S;
  if (!S.inlining) return;
  Cloner cl(kInlineMaxNodes);
  InlineBody ib;
  if (!inline_body(f, callee->proto, cl, &ib)) {
    ++S.stats.inline_declined;
    return;
  }
  Proto* P = owner_proto(f);
  cl.commit(*P);
  MethodInline* neu = P->make<MethodInline>(site->obj_, site->name_, site->args_, ib);
  neu->cache = site->cache;
  site->rewire(neu);
  ++S.stats.rewrites;
  ++S.stats.inlined_sites;
}

}  // namespace
