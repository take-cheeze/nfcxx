// The tier's read-only view of the node classes (docs/notes/ast.md, "Tiering"). This file is not a translation unit: it is
// #included by nfcast_nodes.cpp, after the anonymous namespace that holds the node classes, so that it can name them. It turns
// a node into a TierView (nfcast_tier.hpp): the kind of the node, its operator and its children, and nothing else. A class that is
// not listed here is K_NONE, which makes the function that contains it ineligible. The nodes are never modified.
//
// A change to the node classes (a new class, a renamed field) has to be mirrored here; tests/ast checks the shapes the tier
// accepts and the ones it must refuse.

void tier_view(Node* n, TierView& v) {
  v = TierView();
  v.line = n->line;
  typedef TierView TV;
  if (ConstNode* c = dynamic_cast<ConstNode*>(n)) {
    v.kind = TV::K_CONST;
    v.k = c->v;
  } else if (LocalNode* l = dynamic_cast<LocalNode*>(n)) {
    v.kind = TV::K_LOCAL;
    v.slot = l->slot;
    v.flag = l->cell;
  } else if (UpvalNode* u = dynamic_cast<UpvalNode*>(n)) {
    v.kind = TV::K_UPVAL;
    v.index = u->idx;
  } else if (GlobalNode* g = dynamic_cast<GlobalNode*>(n)) {
    v.kind = TV::K_GLOBAL;
    v.name = g->name;
  } else if (ParenNode* p = dynamic_cast<ParenNode*>(n)) {
    tier_view(p->e_, v);  // `(f(x))`: the call cut to one value, which is what every use of a kernel's result expects anyway
  } else if (ArithBase* a = dynamic_cast<ArithBase*>(n)) {
    v.kind = TV::K_ARITH;
    v.op = a->op;
    v.kids = {a->l_, a->r_};
  } else if (UnaryNode* un = dynamic_cast<UnaryNode*>(n)) {
    v.kind = TV::K_UNARY;
    v.op = un->op;
    v.kids = {un->e_};
  } else if (CmpBase* cm = dynamic_cast<CmpBase*>(n)) {
    v.kind = TV::K_CMP;
    v.op = cm->op;
    v.kids = {cm->l_, cm->r_};
  } else if (EqNode* eq = dynamic_cast<EqNode*>(n)) {
    v.kind = TV::K_EQ;
    v.flag = eq->negate;
    v.kids = {eq->l_, eq->r_};
  } else if (AndNode* an = dynamic_cast<AndNode*>(n)) {
    v.kind = TV::K_AND;
    v.kids = {an->l_, an->r_};
  } else if (OrNode* orn = dynamic_cast<OrNode*>(n)) {
    v.kind = TV::K_OR;
    v.kids = {orn->l_, orn->r_};
  } else if (CallBase* call = dynamic_cast<CallBase*>(n)) {
    v.kind = TV::K_CALL;
    v.kids.push_back(call->fn_);
    for (Node* a2 : call->args_) v.kids.push_back(a2);
    v.multi_last = call->multi_last_;
  } else if (BlockNode* b = dynamic_cast<BlockNode*>(n)) {
    v.kind = TV::K_BLOCK;
    v.kids = b->stmts_;
  } else if (LocalDeclNode* d = dynamic_cast<LocalDeclNode*>(n)) {
    v.kind = TV::K_DECL;
    for (const LocalSlot& s : d->vars_) {
      v.slots.push_back(s.slot);
      if (s.captured) v.captured = true;
    }
    v.kids = d->exprs_;
    v.multi_last = d->multi_last_;
  } else if (AssignLocal* al = dynamic_cast<AssignLocal*>(n)) {
    v.kind = TV::K_ASSIGN;
    v.slots.push_back(al->target_->slot);
    v.tkinds.push_back(al->target_->cell ? TV::T_CELL : TV::T_LOCAL);
    if (al->target_->cell) v.captured = true;
    v.kids = {al->val_};
  } else if (AssignUpval* au = dynamic_cast<AssignUpval*>(n)) {
    v.kind = TV::K_ASSIGN;
    v.slots.push_back(au->idx);
    v.tkinds.push_back(TV::T_UPVAL);
    v.captured = true;
    v.kids = {au->val_};
  } else if (AssignMulti* am = dynamic_cast<AssignMulti*>(n)) {
    v.kind = TV::K_ASSIGN;
    for (Node* t : am->targets_) {
      LocalNode* tl = dynamic_cast<LocalNode*>(t);
      UpvalNode* tu = dynamic_cast<UpvalNode*>(t);
      if (tl) {
        v.slots.push_back(tl->slot);
        v.tkinds.push_back(tl->cell ? TV::T_CELL : TV::T_LOCAL);
        if (tl->cell) v.captured = true;
      } else if (tu) {
        v.slots.push_back(tu->idx);
        v.tkinds.push_back(TV::T_UPVAL);
        v.captured = true;
      } else {
        v.slots.push_back(-1);  // a global or an indexed target: not a kernel
        v.tkinds.push_back(TV::T_OTHER);
        v.captured = true;
      }
    }
    v.kids = am->exprs_;
    v.multi_last = am->multi_last_;
  } else if (IfNode* ifn = dynamic_cast<IfNode*>(n)) {
    v.kind = TV::K_IF;
    v.kids = ifn->conds_;
    v.blocks = ifn->blocks_;
    v.els = ifn->else_;
  } else if (WhileNode* w = dynamic_cast<WhileNode*>(n)) {
    v.kind = TV::K_WHILE;
    v.cond = w->cond_;
    v.blocks = {w->body_};
  } else if (RepeatNode* r = dynamic_cast<RepeatNode*>(n)) {
    v.kind = TV::K_REPEAT;
    v.cond = r->cond_;
    v.blocks = {r->body_};
  } else if (NumForNode* nf = dynamic_cast<NumForNode*>(n)) {
    v.kind = TV::K_FOR;
    v.slots = {nf->var_.slot};
    v.captured = nf->var_.captured;
    v.kids = {nf->start_, nf->limit_, nf->step_};
    v.blocks = {nf->body_};
  } else if (ReturnNode* ret = dynamic_cast<ReturnNode*>(n)) {
    v.kind = TV::K_RETURN;
    v.kids = ret->exprs_;
    v.multi_last = ret->multi_last_;
    v.tail = ret->exprs_.size() == 1 && ret->exprs_[0]->is_call();  // the interpreter's own test (ReturnNode's constructor)
  } else if (dynamic_cast<BreakNode*>(n)) {
    v.kind = TV::K_BREAK;
  }
}
