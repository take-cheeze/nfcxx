// nfcuop stage 2: patterns, the pattern matcher and graph_rewrite. See nfcuop.hpp.
#include "nfcuop.hpp"

namespace nfcuop {

const UOp* Match::operator[](const std::string& name) const {
  auto it = b_.find(name);
  if (it == b_.end()) throw Error("pattern name not bound: " + name);
  return it->second;
}

Pat Pat::any(const std::string& name) {
  Pat p;
  p.kind_ = Any;
  p.name_ = name;
  return p;
}
Pat Pat::cvar(const std::string& name) {
  Pat p;
  p.kind_ = Cvar;
  p.name_ = name;
  return p;
}
Pat Pat::cval(double v) {
  Pat p;
  p.kind_ = Cval;
  p.cval_ = v;
  return p;
}
Pat Pat::op(Op op, const std::string& name) {
  Pat p;
  p.kind_ = OpNode;
  p.op_ = op;
  p.name_ = name;
  return p;
}
Pat Pat::op(Op op, std::vector<Pat> src, const std::string& name) {
  Pat p = Pat::op(op, name);
  p.src_ = std::move(src);
  p.any_src_ = false;
  return p;
}

bool Pat::matches(const UOp* u, Match& m) const {
  Match saved = m;
  bool ok = true;
  if (has_dtype_ && u->dtype != dtype_) ok = false;
  if (ok) {
    switch (kind_) {
      case Any: break;
      case Cvar: ok = u->is_const(); break;
      case Cval:
        ok = u->is_const() && (is_float(u->dtype) ? u->value.f == cval_ : static_cast<double>(u->value.i) == cval_);
        break;
      case OpNode:
        ok = u->op == op_;
        if (ok && !any_src_) {
          ok = u->src.size() == src_.size();
          if (ok) {
            bool done = false;
            if (!ordered_ && is_commutative(op_) && src_.size() == 2) {
              Match before = m;
              if (src_[0].matches(u->src[0], m) && src_[1].matches(u->src[1], m)) done = true;
              else m = before;
              if (!done && src_[0].matches(u->src[1], m) && src_[1].matches(u->src[0], m)) done = true;
              ok = done;
            } else {
              for (size_t k = 0; ok && k < src_.size(); k++) ok = src_[k].matches(u->src[k], m);
            }
          }
        }
        break;
    }
  }
  if (ok && !name_.empty()) {
    auto it = m.b_.find(name_);
    if (it == m.b_.end()) m.b_[name_] = u;
    else ok = it->second == u;
  }
  if (!ok) m = saved;
  return ok;
}

PatternMatcher& PatternMatcher::add(const Pat& pat, RuleFn fn, const std::string& label) {
  rules_.push_back(Rule{pat, std::move(fn), label});
  return *this;
}

PatternMatcher& PatternMatcher::extend(const PatternMatcher& other) {
  rules_.insert(rules_.end(), other.rules_.begin(), other.rules_.end());
  return *this;
}

const UOp* PatternMatcher::apply(Graph& g, const UOp* u) const {
  for (const Rule& r : rules_) {
    Match m;
    if (!r.pat.matches(u, m)) continue;
    const UOp* out = r.fn(g, m);
    if (out && out != u) return out;
  }
  return nullptr;
}

namespace {
struct Rewriter {
  Graph& g;
  const PatternMatcher& pm;
  size_t max_steps;
  size_t steps = 0;
  std::unordered_map<const UOp*, const UOp*> memo;

  const UOp* go(const UOp* n, int nest) {
    auto it = memo.find(n);
    if (it != memo.end()) return it->second;
    std::vector<const UOp*> src;
    bool changed = false;
    for (const UOp* s : n->src) {
      const UOp* r = go(s, nest);
      changed |= r != s;
      src.push_back(r);
    }
    const UOp* cur = changed ? g.rebuild(n, src) : n;
    const UOp* res = cur;
    if (const UOp* r = pm.apply(g, cur)) {
      if (++steps > max_steps) throw Error("graph_rewrite: no fixed point after " + std::to_string(max_steps) + " rule applications");
      if (nest >= 2000) throw Error("graph_rewrite: replacements nest too deeply (rules that undo each other?)");
      res = go(r, nest + 1);
    }
    memo[n] = res;
    memo[cur] = res;
    memo[res] = res;
    return res;
  }
};
}  // namespace

const UOp* graph_rewrite(Graph& g, const PatternMatcher& pm, const UOp* root, size_t max_steps) {
  Rewriter rw{g, pm, max_steps, 0, {}};
  return rw.go(root, 0);
}

}  // namespace nfcuop
