// BC2CPP_HOST_CLASS_MUTATIONS=DIR (trace_host.cxx): records every class,
// module, singleton class and iclass the boot leaves, and at exit writes to
// DIR/PID.tsv what the run changed in them: a class-level instance variable or
// constant set, changed or removed, a method-table layer added or grown, a new
// superclass link (include/prepend), and the classes made after the boot. What
// the boot leaves and nothing changes could live in flash.
#pragma once

#include <unistd.h>

#include <map>
#include <string>
#include <utility>
#include <vector>

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>

namespace class_mutations {

struct State {
  int tt = 0;
  struct RClass* super = nullptr;
  std::vector<std::pair<mrb_sym, mrb_value>> iv;
  std::vector<std::pair<const void*, int>> mt;
};

inline mrb_state* g_mrb = nullptr;
inline const char* g_path = nullptr;
inline std::map<struct RClass*, State> g_boot;

inline bool class_like(const struct RBasic* o) {
  return o->tt == MRB_TT_CLASS || o->tt == MRB_TT_MODULE ||
         o->tt == MRB_TT_SCLASS || o->tt == MRB_TT_ICLASS;
}

inline int iv_cb(mrb_state*, mrb_sym s, mrb_value v, void* p) {
  static_cast<std::vector<std::pair<mrb_sym, mrb_value>>*>(p)->emplace_back(s,
                                                                            v);
  return 0;
}

inline State state_of(mrb_state* M, struct RClass* c) {
  State s;
  s.tt = c->tt;
  s.super = c->super;
  if (c->tt != MRB_TT_ICLASS)
    mrb_iv_foreach(M, mrb_obj_value(c), iv_cb, &s.iv);
  for (const mrb_mt_tbl* t = c->mt; t; t = t->next)
    s.mt.emplace_back(t, t->size);
  return s;
}

inline std::string name_of(mrb_state* M, struct RClass* c) {
  if (c->tt == MRB_TT_ICLASS)
    return "iclass:" + name_of(M, c->c);
  if (c->tt == MRB_TT_SCLASS) {
    mrb_value a = mrb_iv_get(M, mrb_obj_value(c), MRB_SYM(__attached__));
    if (!mrb_immediate_p(a) &&
        (mrb_type(a) == MRB_TT_CLASS || mrb_type(a) == MRB_TT_MODULE ||
         mrb_type(a) == MRB_TT_SCLASS))
      return "#<Class:" + name_of(M, mrb_class_ptr(a)) + ">";
    return "";  // an ordinary object's singleton class: stays on the heap
  }
  const char* n = mrb_class_name(M, c);
  return n ? n : "(anonymous)";
}

inline int collect(mrb_state* M, struct RBasic* o, void* p) {
  if (class_like(o)) {
    auto* m = static_cast<std::map<struct RClass*, State>*>(p);
    struct RClass* c = reinterpret_cast<struct RClass*>(o);
    (*m)[c] = state_of(M, c);
  }
  return MRB_EACH_OBJ_OK;
}

inline void boot(mrb_state* M, const char* path) {
  g_mrb = M;
  g_path = path;
  mrb_objspace_each_objects(M, collect, &g_boot);
}

inline std::string sym(mrb_state* M, mrb_sym s) {
  mrb_int len = 0;
  const char* n = mrb_sym_name_len(M, s, &len);
  return n ? std::string(n, len) : "?";
}

inline void report() {
  mrb_state* M = g_mrb;
  if (!M)
    return;
  M->gc.disabled = TRUE;
  std::map<struct RClass*, State> now;
  mrb_objspace_each_objects(M, collect, &now);
  const std::string out =
      std::string(g_path) + "/" + std::to_string(getpid()) + ".tsv";
  FILE* f = fopen(out.c_str(), "w");
  if (!f) {
    perror("TRACE_HOST class mutations");
    return;
  }
  long objects_sclass = 0;
  fprintf(f, "boot_classes\t%zu\n", g_boot.size());
  for (auto& [c, s] : now) {
    auto it = g_boot.find(c);
    std::string name = name_of(M, c);
    if (it == g_boot.end() || it->second.tt != s.tt) {
      if (name.empty())
        ++objects_sclass;
      else
        fprintf(f, "new\t%s\t%d\n", name.c_str(), s.tt);
      continue;
    }
    const State& b = it->second;
    if (name.empty())
      continue;
    if (b.super != s.super)
      fprintf(f, "super\t%s\t%s\n", name.c_str(),
              s.super ? name_of(M, s.super).c_str() : "nil");
    std::map<mrb_sym, mrb_value> bi(b.iv.begin(), b.iv.end());
    for (auto& [k, v] : s.iv) {
      auto bit = bi.find(k);
      if (bit == bi.end())
        fprintf(f, "iv_add\t%s\t%s\n", name.c_str(), sym(M, k).c_str());
      else if (!mrb_obj_eq(M, bit->second, v))
        fprintf(f, "iv_set\t%s\t%s\n", name.c_str(), sym(M, k).c_str());
      if (bit != bi.end())
        bi.erase(bit);
    }
    for (auto& [k, v] : bi)
      fprintf(f, "iv_del\t%s\t%s\n", name.c_str(), sym(M, k).c_str());
    if (b.mt != s.mt)
      fprintf(f, "mt\t%s\t%zu->%zu layers\n", name.c_str(), b.mt.size(),
              s.mt.size());
  }
  fprintf(f, "object_singleton_classes\t%ld\n", objects_sclass);
  fclose(f);
}

}  // namespace class_mutations
