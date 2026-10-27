// The function lowering and the module (scripts/pathb-spirv-emit.rb: class SpvModule, class SFn, emit_module). Each method
// is the Ruby's method of the same name. The order of the ids is the Ruby's: an instruction's operands are evaluated left to
// right (braced lists here: C++ evaluates their elements in order) before the instruction takes its result id.
#include "emit.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <tuple>
#include <unordered_set>

#include "forms.hpp"
#include "ir.hpp"
#include "spv.hpp"

namespace {

enum : uint32_t { IADD = 128, ISUB = 130, IMUL = 132 };

// GLSL.std.450 instruction numbers for the SYCL math operations (detail::math_op in sycl.hpp), the Ruby's GLSL_OF_MATH
int glsl_of_math(int64_t k) {
  static const std::map<int64_t, int> t = {
      {1, 31},  {2, 27},  {3, 28},  {4, 13},  {5, 14},  {6, 15},  {7, 4},   {8, 8},   {9, 9},   {10, 3},
      {11, 1},  {12, 32}, {13, 29}, {14, 30}, {15, 16}, {16, 17}, {17, 18}, {18, 19}, {19, 20}, {20, 21},
      {32, 26}, {33, 37}, {34, 40}, {35, 25}, {48, 50}, {49, 43}, {50, 46}, {21, 1002}, {22, 1000}, {23, 1001}};
  auto it = t.find(k);
  return it == t.end() ? 0 : it->second;
}

// libm builtins that libstdc++ calls for float arguments (the Ruby's LIBM_GLSL)
int libm_glsl(const std::string &n0) {
  static const std::map<std::string, int> t = {
      {"sqrtf", 31}, {"expf", 27},  {"logf", 28},   {"sinf", 13},  {"cosf", 14},  {"tanf", 15},  {"fabsf", 4},
      {"floorf", 8}, {"ceilf", 9},  {"truncf", 3},  {"roundf", 1}, {"exp2f", 29}, {"log2f", 30}, {"asinf", 16},
      {"acosf", 17}, {"atanf", 18}, {"sinhf", 19},  {"coshf", 20}, {"tanhf", 21}, {"powf", 26},  {"atan2f", 25},
      {"fminf", 37}, {"fmaxf", 40}, {"fmaf", 50}};
  std::string n = n0.compare(0, 10, "__builtin_") == 0 ? n0.substr(10) : n0;
  auto it = t.find(n);
  return it == t.end() ? 0 : it->second;
}

bool wide(const Ty &t) {
  return t.k == Ty::Ptr || (t.k == Ty::Int && !t.boolean && t.size == 8) || (t.k == Ty::Float && t.size == 8);
}

bool is_reg(const Node &x) { return x.kind == Node::Atom && !x.text.empty() && x.text[0] == '%'; }

const Node *find_head(const Node &s, size_t from, const char *h) {
  for (size_t i = from; i < s.items.size(); i++)
    if (head_is(s.items[i], h)) return &s.items[i];
  return nullptr;
}

std::vector<const Node *> drop(const Node &x, size_t n) {
  std::vector<const Node *> v;
  for (size_t i = n; i < x.items.size(); i++) v.push_back(&x.items[i]);
  return v;
}

struct SFn;

// The module's shared state (the Ruby's class SpvModule).
struct SpvModule {
  Spv *spv;
  bool kernel_cl;
  uint32_t push = 0, gid, lid, wid, sp = 0, dead = 0;
  uint32_t spec[3];
  int64_t stack_bytes = 0;
  std::unordered_map<std::string, SFn *> fns, fns_wgs;
  Mod *irmod = nullptr;
  bool subgroup_used = false;
  bool has_wgs = false;   // the Ruby's smod.wgs (nil in the Vulkan module)
  std::map<std::pair<std::string, std::string>, int64_t> wgs;
  int64_t wgs_total = 0;
  uint32_t wgs_var = 0;

  SpvModule(Spv *s, bool kcl) : spv(s), kernel_cl(kcl) {
    push = kcl ? 0 : s->push_var();
    gid = s->builtin_input(BUILTIN_GLOBAL_INVOCATION_ID);
    lid = s->builtin_input(BUILTIN_LOCAL_INVOCATION_ID);
    wid = s->builtin_input(BUILTIN_WORKGROUP_ID);
    sp = kcl ? 0 : s->private_var(s->t_int(64));
    dead = kcl ? 0 : s->private_var(s->t_int(32));
    spec[0] = s->spec_u32(0, 1);
    spec[1] = s->spec_u32(1, 1);
    spec[2] = s->spec_u32(2, 1);
    if (!kcl) s->workgroup_size({spec[0], spec[1], spec[2]});
  }
  uint32_t push_struct_type() { return spv->t_push_struct(); }
  uint32_t push_class() const { return kernel_cl ? SC_CROSSWG : SC_PUSH_CONSTANT; }
};

struct Reg {
  bool var;
  uint32_t id;
  Ty ty;
};

struct Local {
  uint32_t var = 0;
  Ty ty;
};

struct Opnd {
  uint32_t id;
  Ty ty;
};

// One IR function (or a kernel's entry wrapper) in SPIR-V (the Ruby's class SFn).
struct SFn {
  Node *form;
  uint32_t fid;
  SpvModule *mod;
  Spv *spv;
  bool wgs_mode;
  std::string name;
  std::vector<Ty> ptypes;
  std::optional<Ty> ret;
  std::unordered_map<std::string, int64_t> slots;
  std::unordered_map<std::string, int64_t> wgs;
  OMap<Local> locals;
  int64_t frame = 0;
  std::vector<Node *> body;
  std::vector<Inst> vars, code, param_lines;
  std::unordered_map<std::string, Reg> regs;
  bool term_ = false;
  struct Loop {
    uint32_t brk, cont;   // cont 0: a switch
  };
  std::vector<Loop> loops;
  std::unordered_map<std::string, uint32_t> labels;
  std::optional<std::string> pending_brk;
  std::vector<uint32_t> param_ids;
  std::vector<std::string> callees;
  bool has_state = false;
  uint32_t st_push = 0, st_sp = 0, st_dead = 0;
  uint32_t ftype = 0, ret_t = 0, oldsp_var = 0, frame_var = 0;
  std::vector<uint32_t> state_types, state_param_ids;
  bool sg_used = false;

  SFn(Node *f, uint32_t id, SpvModule *m, bool wm = false) : form(f), fid(id), mod(m), spv(m->spv), wgs_mode(wm) {
    name = f ? to_s(f->items.at(1)) : "wrapper";
    if (f) setup();
  }

  uint32_t psb_sc() const { return mod->kernel_cl ? SC_CROSSWG : SC_PSB; }

  enum State { S_PUSH, S_SP, S_DEAD };
  uint32_t state(State s) const {
    if (has_state) return s == S_PUSH ? st_push : s == S_SP ? st_sp : st_dead;
    return s == S_PUSH ? mod->push : s == S_SP ? mod->sp : mod->dead;
  }

  // ---- the instruction stream

  void ins(Inst i) {
    if (term_) return;
    code.push_back(std::move(i));
  }
  void term(Inst i) {
    if (term_) return;
    code.push_back(std::move(i));
    term_ = true;
  }
  void label(uint32_t l) {
    code.push_back({248, l});
    term_ = false;
  }
  // res(opcode, {rtype, operands...}): the operands are evaluated (in order) before the result id is taken
  uint32_t res(uint32_t op, std::initializer_list<uint32_t> l) { return res_v(op, std::vector<uint32_t>(l)); }
  uint32_t res_v(uint32_t op, const std::vector<uint32_t> &l) {
    uint32_t i = spv->id();
    Inst v{op, l[0], i};
    v.insert(v.end(), l.begin() + 1, l.end());
    ins(std::move(v));
    return i;
  }
  uint32_t new_label() { return spv->id(); }
  void branch(uint32_t l) { term({249, l}); }
  void cond_branch(uint32_t c, uint32_t t, uint32_t f) { term({250, c, t, f}); }
  uint32_t var_decl(uint32_t t) {
    uint32_t pt = spv->t_ptr(SC_FUNCTION, t);
    uint32_t v = spv->id();
    vars.push_back({59, pt, v, SC_FUNCTION});
    return v;
  }

  uint32_t t32() { return spv->t_int(32); }
  uint32_t t64() { return spv->t_int(64); }
  uint32_t tbool() { return spv->t_bool(); }

  // the zero of an IR type (0: void)
  uint32_t zero_of(const Ty &t) {
    if (t.k == Ty::Void) return 0;
    sty(t);
    if (t.k == Ty::Int && t.boolean) return spv->c_bool(false);
    if (t.k == Ty::Float) return t.size == 4 ? spv->c_float(32, 0.0) : spv->c_float(64, 0.0);
    return spv->c_int(t.k == Ty::Ptr ? 64 : (t.size * 8 > 32 ? 64 : 32), 0);
  }

  uint32_t sty(const Ty &t) {
    switch (t.k) {
      case Ty::Void: return spv->t_void();
      case Ty::Ptr: return spv->t_int(64);
      case Ty::Int:
        if (t.boolean) return spv->t_bool();
        return t.size == 8 ? spv->t_int(64) : spv->t_int(32);
      case Ty::Float: return spv->t_float(t.size * 8);
    }
    throw Refused("value of type ?");
  }

  // ---- setup (the Ruby's setup)

  void setup() {
    std::vector<const Node *> slot_forms;
    for (size_t i = 2; i < form->items.size(); i++) {
      Node &f = form->items[i];
      const std::string *h = head_of(f);
      if (h && *h == "ret") {
        Ty t = parse_type(f.items.at(1));
        if (t.k == Ty::Void) ret.reset();
        else ret = t;
      } else if (h && *h == "params") {
        for (size_t k = 1; k < f.items.size(); k++) {
          const Node &p = f.items[k];
          size_t idx = k - 1;
          if (head_is(p, "ellipsis")) throw Refused("variadic function " + name);
          std::string reg = "%" + std::to_string(idx);
          if (head_is(p, "param")) {
            if (!(p.items.size() > 1 && p.items[1].atom_is(reg.c_str()))) throw BadIR("parameter register must be " + reg);
            ptypes.push_back(parse_type(p.items.at(3)));
          } else if (head_is(p, "sret")) {
            if (!(p.items.size() > 1 && p.items[1].atom_is(reg.c_str()))) throw BadIR("parameter register must be " + reg);
            ptypes.push_back(ty_ptr());
          } else {
            throw Refused("parameter form " + form_text(p));
          }
        }
      } else if (h && (*h == "static" || *h == "weak")) {
      } else if (h && *h == "slot") {
        slot_forms.push_back(&f);
      } else {
        body.push_back(&f);
      }
    }
    fold_fnptr_slots(body, slot_forms);
    std::unordered_map<std::string, std::vector<std::optional<Ty>>> direct;
    std::unordered_set<std::string> escaped;
    for (Node *s : body) scan_slots(*s, direct, escaped);
    int64_t off = 0;
    for (const Node *f : slot_forms) {
      std::string sname = to_s(f->items.at(1));
      if (mod->has_wgs) {
        auto it = mod->wgs.find({name, sname});
        if (it != mod->wgs.end()) {
          wgs[sname] = it->second;
          continue;
        }
      }
      int64_t size = f->items.size() == 5 ? as_int(f->items[3]) : 4;
      int64_t align = f->items.size() == 5 ? as_int(f->items[4]) : 4;
      std::optional<Ty> ty;
      if (scalar_form(f->items.at(2))) ty = parse_type(f->items[2]);
      auto du = direct.find(sname);
      bool all = true;
      if (du != direct.end())
        for (auto &u : du->second)
          if (!(u && ty && *u == *ty)) all = false;
      if (ty && ty->k != Ty::Void && !escaped.count(sname) && all) {
        locals.set(sname, Local{0, *ty});   // the variable is declared when the function is compiled
      } else {
        if (align < 8) align = 8;
        off = (off + align - 1) / align * align;
        slots[sname] = off;
        off += size;
      }
    }
    frame = (off + 15) / 16 * 16;
    std::vector<std::string> calls;
    collect_calls(*form, calls);
    std::unordered_set<std::string> seen;
    for (auto &c : calls)
      if (mod->irmod->defs.has(c) && seen.insert(c).second) callees.push_back(c);
  }

  // ---- operands

  uint32_t sty_of_push(int member) { return PUSH_SIZES[member] == 8 ? spv->t_int(64) : spv->t_int(32); }

  uint32_t push_load(int member) {
    uint32_t pc = mod->push_class();
    uint32_t pt = spv->t_ptr(pc, sty_of_push(member));
    uint32_t p = res(65, {pt, state(S_PUSH), spv->c_u32(member)});
    return res(61, {sty_of_push(member), p});
  }

  uint32_t ptr_to_device(uint32_t v) {
    uint32_t hlo = push_load(P_HLO), hsize = push_load(P_HSIZE), dbase = push_load(P_DBASE);
    uint32_t inside = res(176, {tbool(), res(ISUB, {t64(), v, hlo}), hsize});
    uint32_t moved = res(IADD, {t64(), v, res(ISUB, {t64(), dbase, hlo})});
    return res(169, {t64(), inside, moved, v});
  }

  uint32_t ptr_to_host(uint32_t v) {
    uint32_t hlo = push_load(P_HLO), hsize = push_load(P_HSIZE), dbase = push_load(P_DBASE);
    uint32_t inside = res(176, {tbool(), res(ISUB, {t64(), v, dbase}), hsize});
    uint32_t moved = res(ISUB, {t64(), v, res(ISUB, {t64(), dbase, hlo})});
    return res(169, {t64(), inside, moved, v});
  }

  uint32_t builtin_component(uint32_t var, uint32_t k) {
    if (mod->kernel_cl) {
      uint32_t v = res(61, {spv->builtin_vec_t(), var});
      uint32_t c = res(81, {t64(), v, k});
      return res(113, {t32(), c});
    }
    uint32_t v = res(61, {spv->t_vec3(), var});
    return res(81, {t32(), v, k});
  }

  uint32_t global_comp(int k) {
    uint32_t g = builtin_component(mod->gid, k);
    uint32_t off = push_load(P_OX + k);
    return res(IADD, {t32(), g, res(IMUL, {t32(), off, mod->spec[k]})});
  }

  uint32_t group_comp(int k) {
    uint32_t w = builtin_component(mod->wid, k);
    return res(IADD, {t32(), w, push_load(P_OX + k)});
  }

  Opnd operand(const Node &x) {
    if (is_reg(x)) {
      auto it = regs.find(x.text);
      if (it == regs.end()) throw BadIR("register " + x.text + " is used before it is set");
      Reg &r = it->second;
      if (!r.var) return {r.id, r.ty};
      Ty ty = r.ty;
      uint32_t id = r.id;
      return {res(61, {sty(ty), id}), ty};
    }
    const std::string *h = head_of(x);
    if (h && *h == "const") {
      Ty ty = parse_type(x.items.at(1));
      if (ty.k == Ty::Float) {
        std::string text = x.items.size() > 2 ? to_s(x.items[2]) : std::string();
        return {float_const(ty.size * 8, text), ty};
      }
      if (ty.k == Ty::Int && ty.boolean) return {spv->c_bool(as_int(x.items.at(2)) != 0), ty};
      int64_t v = as_int(x.items.at(2));
      return {spv->c_int(wide(ty) ? 64 : 32, v), ty};
    }
    if (h && *h == "null") return {spv->c_u64(0), ty_ptr()};
    if (h && (*h == "sret" || *h == "byval")) return operand(x.items.at(2));
    if (x.is_sym('$')) {
      auto w = wgs.find(x.text);
      if (w != wgs.end()) {
        // a work-group static: the group's region after the scratch tail (one object per group)
        uint32_t lu = res(IADD, {t64(), local_base(), to_u64(push_load(P_LOCAL_USER), U32)});
        return {res(IADD, {t64(), lu, spv->c_u64(1024 + w->second)}), ty_ptr()};
      }
      auto s = slots.find(x.text);
      if (s == slots.end() && locals.has(x.text)) throw Refused("address of the scalar slot " + x.text);
      if (s == slots.end()) throw BadIR("slot " + x.text + " is not declared");
      int64_t off = s->second;
      return {res(IADD, {t64(), frame_base(), spv->c_u64(off)}), ty_ptr()};
    }
    if (x.is_sym('@')) {
      int64_t off = mod->irmod->static_offset(x.text);
      return {res(IADD, {t64(), push_load(P_STATICS), spv->c_u64(off)}), ty_ptr()};
    }
    if (x.is_sym('&')) throw Refused("address of function " + x.text);
    throw Refused("operand " + form_text(x));
  }

  uint32_t float_const(int bits, const std::string &text) {
    if (text == "+Infinity" || text == "Infinity") return spv->c_float_bits(bits, 0x7f800000);
    if (text == "-Infinity") return spv->c_float_bits(bits, 0xff800000);
    bool ok = text.find_first_of("0123456789") != std::string::npos;
    for (char c : text)
      if (!std::strchr("0123456789.eE+-", c) || c == 0) ok = false;
    if (!ok) throw Refused("float constant " + text);
    return spv->c_float(bits, ruby_to_f(text));
  }

  uint32_t frame_base() { return res(61, {t64(), frame_var}); }

  // ---- integer helpers

  uint32_t canon(uint32_t id, const Ty &t) {
    if (!(t.k == Ty::Int && !t.boolean && t.size < 4)) return id;
    uint32_t sh = 32 - t.size * 8;
    uint32_t l = res(196, {t32(), id, spv->c_u32(sh)});
    return res(t.sign ? 195 : 194, {t32(), l, spv->c_u32(sh)});
  }

  uint32_t bool_to_u32(uint32_t b) { return res(169, {t32(), b, spv->c_u32(1), spv->c_u32(0)}); }

  uint32_t u32_of(uint32_t id, const Ty &ty) {
    if (ty.k == Ty::Int && ty.boolean) return bool_to_u32(id);
    if (!wide(ty)) return id;
    return res(113, {t32(), id});
  }

  uint32_t to_u64(uint32_t id, const Ty &ty) {
    if (wide(ty) || ty.k == Ty::Ptr) return id;
    if (ty.k == Ty::Int && ty.boolean) return res(113, {t64(), bool_to_u32(id)});
    if (ty.sign) return res(114, {t64(), id});
    return res(113, {t64(), id});
  }

  uint32_t int_const_of(const Ty &t, int64_t v) { return spv->c_int(wide(t) ? 64 : 32, v); }

  // the trap helper: set the flag to code, mark the invocation dead, return zero
  void trap(uint32_t code_) {
    uint32_t flag_ptr = res(120, {spv->t_ptr(psb_sc(), t32()), push_load(P_FLAG)});
    ins({239, t32(), spv->id(), flag_ptr, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), spv->c_u32(code_)});
    uint32_t d = state(S_DEAD);
    uint32_t one = spv->c_u32(1);
    t32();
    ins({62, d, one});
    emit_return(std::nullopt);
  }

  void emit_return(std::optional<uint32_t> val) {
    if (frame > 0) {
      uint32_t old = res(61, {t64(), oldsp_var});
      ins({62, state(S_SP), old});
    }
    if (!ret) {
      term({253});
    } else {
      uint32_t v = val ? *val : zero_of(*ret);
      term({254, v});
    }
  }

  void trap_if(uint32_t cond, uint32_t code_) {
    uint32_t t = new_label();
    uint32_t m = new_label();
    ins({247, m, 0});
    cond_branch(cond, t, m);
    label(t);
    trap(code_);
    label(m);
  }

  void check_dead_after_call() {
    uint32_t d = res(61, {t32(), state(S_DEAD)});
    uint32_t c = res(171, {tbool(), d, spv->c_u32(0)});
    uint32_t t = new_label();
    uint32_t m = new_label();
    ins({247, m, 0});
    cond_branch(c, t, m);
    label(t);
    emit_return(std::nullopt);
    label(m);
  }

  // ---- memory

  uint32_t psb_ptr(const Ty &t) { return spv->t_ptr(psb_sc(), sty(t)); }
  uint32_t addr_ptr(uint32_t addr, const Ty &t) { return res(120, {psb_ptr(t), addr}); }
  uint32_t aligned_word_addr(uint32_t addr) {
    uint32_t mask = spv->c_u64((int64_t)0xfffffffffffffffcull);
    return res(199, {t64(), addr, mask});
  }
  uint32_t byte_shift(uint32_t addr) {
    uint32_t low = res(199, {t64(), addr, spv->c_u64(3)});
    uint32_t l32 = res(113, {t32(), low});
    return res(132, {t32(), l32, spv->c_u32(8)});
  }
  uint32_t load_word(uint32_t addr) {
    uint32_t wp = res(120, {spv->t_ptr(psb_sc(), t32()), aligned_word_addr(addr)});
    return res(61, {t32(), wp, 2, 4});
  }

  uint32_t heap_load(uint32_t addr, const Ty &t) {
    if (t.k == Ty::Int && (t.size <= 2 || t.boolean)) {
      uint32_t w = load_word(addr);
      uint32_t sh = byte_shift(addr);
      int bits = t.boolean ? 8 : t.size * 8;
      uint32_t v = res(194, {t32(), w, sh});
      v = res(199, {t32(), v, spv->c_u32((1ll << bits) - 1)});
      if (t.boolean) return res(171, {tbool(), v, spv->c_u32(0)});
      return canon(v, t);
    }
    uint32_t p = addr_ptr(addr, t);
    uint32_t align = t.k == Ty::Ptr ? 8 : t.size;
    uint32_t rt = sty(t);
    uint32_t v = res_load(p, rt, align);
    return t.k == Ty::Ptr ? ptr_to_device(v) : v;
  }

  uint32_t res_load(uint32_t p, uint32_t rtype, uint32_t align) {
    uint32_t i = spv->id();
    ins({61, rtype, i, p, 2, align});
    return i;
  }

  void no_wgs_var() {
    if (!mod->wgs_var) throw Refused("a work-group static access in " + name + " without the Workgroup variable");
  }

  uint32_t mem_load(uint32_t addr, const Ty &t) {
    if (!wgs_mode) return heap_load(addr, t);
    no_wgs_var();
    auto [rel, inside] = wgs_range(addr);
    uint32_t b_in = new_label(), b_out = new_label(), merge = new_label();
    ins({247, merge, 0});
    cond_branch(inside, b_in, b_out);
    label(b_in);
    uint32_t vin = wgs_load_val(rel, t);
    if (t.k == Ty::Ptr) vin = ptr_to_device(vin);
    branch(merge);
    label(b_out);
    uint32_t vout = heap_load(addr, t);
    branch(merge);
    label(merge);
    return res(245, {sty(t), vin, b_in, vout, b_out});
  }

  void mem_store(uint32_t addr, const Ty &t, uint32_t v) {
    if (!wgs_mode) return heap_store(addr, t, v);
    no_wgs_var();
    auto [rel, inside] = wgs_range(addr);
    uint32_t b_in = new_label(), b_out = new_label(), merge = new_label();
    ins({247, merge, 0});
    cond_branch(inside, b_in, b_out);
    label(b_in);
    uint32_t hv = t.k == Ty::Ptr ? ptr_to_host(v) : v;
    wgs_store_val(rel, t, hv);
    branch(merge);
    label(b_out);
    heap_store(addr, t, v);
    branch(merge);
    label(merge);
  }

  std::pair<uint32_t, uint32_t> wgs_range(uint32_t addr) {
    t64();
    uint32_t sbase = res(IADD, {t64(), local_base(), to_u64(push_load(P_LOCAL_USER), U32)});
    sbase = res(IADD, {t64(), sbase, spv->c_u64(1024)});
    uint32_t rel = res(ISUB, {t64(), addr, sbase});
    uint32_t in = res(176, {tbool(), rel, spv->c_u64(mod->wgs_total)});
    return {rel, in};
  }

  uint32_t wgs_word(uint32_t rel, int word_off = 0) {
    t64();
    uint32_t r = word_off == 0 ? rel : res(IADD, {t64(), rel, spv->c_u64(4 * word_off)});
    uint32_t widx = res(113, {t32(), res(194, {t64(), r, spv->c_u64(2)})});
    return res(65, {spv->t_ptr(SC_WORKGROUP, t32()), mod->wgs_var, widx});
  }

  static int wgs_bytes(const Ty &t) {
    if (t.k == Ty::Ptr) return 8;
    if (t.k == Ty::Int && t.boolean) return 1;
    return t.size;
  }

  uint32_t wgs_load_val(uint32_t rel, const Ty &t) {
    t32();
    t64();
    int n = wgs_bytes(t);
    if (n == 8) {
      uint32_t lo = res(113, {t64(), res(61, {t32(), wgs_word(rel, 0)})});
      uint32_t hi = res(113, {t64(), res(61, {t32(), wgs_word(rel, 1)})});
      uint32_t v = res(197, {t64(), lo, res(196, {t64(), hi, spv->c_u64(32)})});
      return t.k == Ty::Float ? res(124, {sty(t), v}) : v;
    }
    uint32_t w = res(61, {t32(), wgs_word(rel)});
    if (n == 4) return t.k == Ty::Float ? res(124, {sty(t), w}) : w;
    int bits = n * 8;
    uint32_t v = res(194, {t32(), w, byte_shift(rel)});
    v = res(199, {t32(), v, spv->c_u32((1ll << bits) - 1)});
    if (t.k == Ty::Int && t.boolean) return res(171, {tbool(), v, spv->c_u32(0)});
    return canon(v, t);
  }

  void wgs_store_val(uint32_t rel, const Ty &t, uint32_t v) {
    t32();
    t64();
    int n = wgs_bytes(t);
    if (n == 8) {
      uint32_t u = t.k == Ty::Float ? res(124, {t64(), v}) : v;
      ins({62, wgs_word(rel, 0), res(113, {t32(), u})});
      ins({62, wgs_word(rel, 1), res(113, {t32(), res(194, {t64(), u, spv->c_u64(32)})})});
      return;
    }
    if (n == 4) {
      uint32_t u = t.k == Ty::Float ? res(124, {t32(), v}) : v;
      ins({62, wgs_word(rel), u});
      return;
    }
    int bits = n * 8;
    int64_t mask = (1ll << bits) - 1;
    uint32_t vv = t.k == Ty::Int && t.boolean ? bool_to_u32(v) : u32_of(v, t);
    vv = res(199, {t32(), vv, spv->c_u32(mask)});
    uint32_t sh = byte_shift(rel);
    uint32_t wp = wgs_word(rel);
    uint32_t clear = res(200, {t32(), res(196, {t32(), spv->c_u32(mask), sh})});
    ins({240, t32(), spv->id(), wp, spv->c_u32(SCOPE_WORKGROUP), spv->c_u32(SEM_RELAXED), clear});
    ins({241, t32(), spv->id(), wp, spv->c_u32(SCOPE_WORKGROUP), spv->c_u32(SEM_RELAXED), res(196, {t32(), vv, sh})});
  }

  void heap_store(uint32_t addr, const Ty &t, uint32_t v) {
    if (t.k == Ty::Int && (t.size <= 2 || t.boolean)) {
      int bits = t.boolean ? 8 : t.size * 8;
      int64_t mask = (1ll << bits) - 1;
      uint32_t vv = t.boolean ? bool_to_u32(v) : u32_of(v, t);
      vv = res(199, {t32(), vv, spv->c_u32(mask)});
      uint32_t sh = byte_shift(addr);
      uint32_t wp = res(120, {spv->t_ptr(psb_sc(), t32()), aligned_word_addr(addr)});
      uint32_t clear = res(196, {t32(), spv->c_u32(mask), sh});
      clear = res(200, {t32(), clear});
      ins({240, t32(), spv->id(), wp, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), clear});
      uint32_t shifted = res(196, {t32(), vv, sh});
      ins({241, t32(), spv->id(), wp, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), shifted});
      return;
    }
    uint32_t p = addr_ptr(addr, t);
    uint32_t align = t.k == Ty::Ptr ? 8 : t.size;
    if (t.k == Ty::Ptr) v = ptr_to_host(v);
    ins({62, p, v, 2, align});
  }

  void not_routed() {
    if (wgs_mode) throw Refused("an atomic on memory in " + name + ", which may be a work-group static (not routed)");
  }

  // the compare-and-swap loop of a float atomic
  void float_atomic(uint32_t p_addr, uint32_t v, int op) {
    not_routed();
    uint32_t expected = var_decl(t32());
    uint32_t wp = res(120, {spv->t_ptr(psb_sc(), t32()), p_addr});
    ins({62, expected, res(61, {t32(), wp, 2, 4})});
    uint32_t hdr = new_label(), bodyl = new_label(), cont = new_label(), merge = new_label(), after = new_label(),
             t1 = new_label();
    branch(hdr);
    label(hdr);
    ins({246, merge, cont, 0});
    branch(bodyl);
    label(bodyl);
    uint32_t old = res(61, {t32(), expected});
    uint32_t f = res(124, {spv->t_float(32), old});
    uint32_t nf;
    if (op == 0) nf = res(129, {spv->t_float(32), f, v});
    else nf = res(12, {spv->t_float(32), spv->glsl_id(), spv->ext_num(op == 1 ? 37 : 40), f, v});
    uint32_t nb = res(124, {t32(), nf});
    uint32_t r = res_cas(wp, expected, nb);
    uint32_t ok = res(170, {tbool(), r, old});
    ins({247, after, 0});
    cond_branch(ok, merge, t1);
    label(t1);
    ins({62, expected, r});
    branch(after);
    label(after);
    branch(cont);
    label(cont);
    branch(hdr);
    label(merge);
  }

  uint32_t res_cas(uint32_t wp, uint32_t expected_var, uint32_t desired) {
    uint32_t e = res(61, {t32(), expected_var});
    return res(230, {t32(), wp, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), spv->c_u32(SEM_RELAXED), desired, e});
  }

  // ---- expressions

  Opnd rval(const Node &x) {
    const std::string *hp = head_of(x);
    std::string h = hp ? *hp : std::string();
    auto arg = [&](size_t i) -> const Node & { return x.items.at(i); };
    if (h == "load" || h == "load.v") {
      Ty ty = parse_type(arg(1));
      if (arg(2).is_sym('$') && locals.has(arg(2).text)) {
        uint32_t st = sty(ty);
        return {res(61, {st, locals.get(arg(2).text)->var}), ty};
      }
      uint32_t a = operand(arg(2)).id;
      if (ty.k == Ty::Void) throw Refused("load of void");
      return {mem_load(a, ty), ty};
    }
    if (h == "bitcast") {
      Opnd v = operand(arg(2));
      if (v.ty.k != Ty::Ptr) throw Refused(std::string("bitcast of a ") + v.ty.kind_name());
      return {v.id, ty_ptr()};
    }
    if (h == "offset") {
      uint32_t b = operand(arg(1)).id;
      return {res(IADD, {t64(), b, spv->c_u64(as_int(arg(2)))}), ty_ptr()};
    }
    if (h == "index") {
      uint32_t b = operand(arg(1)).id;
      Opnd i = operand(arg(2));
      uint32_t size = is_reg(arg(3)) ? operand(arg(3)).id : spv->c_u64(as_int(arg(3)));
      uint32_t off = to_i64(i.id, i.ty);
      return {res(IADD, {t64(), b, res(IMUL, {t64(), off, size})}), ty_ptr()};
    }
    if (h == "pdiff") {
      uint32_t a = operand(arg(1)).id;
      uint32_t b = operand(arg(2)).id;
      uint32_t d = res(ISUB, {t64(), a, b});
      return {res(135, {t64(), d, spv->c_u64(as_int(arg(3)))}), ty_int(8, true)};
    }
    if (h == "wadd" || h == "wsub" || h == "wmul") {
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      uint32_t b = operand(arg(3)).id;
      uint32_t op = h == "wadd" ? IADD : h == "wsub" ? ISUB : IMUL;
      return {canon(res(op, {sty(ty), a, b}), ty), ty};
    }
    if (h == "wneg") {
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      return {canon(res(ISUB, {sty(ty), zero_of(ty), a}), ty), ty};
    }
    if (h == "cdiv" || h == "crem") {
      Ty ty = parse_type(arg(1));
      return {checked_div(h, ty, arg(2), arg(3)), ty};
    }
    if (h == "cshl" || h == "cshr") {
      Ty ty = parse_type(arg(1));
      return {checked_shift(h, ty, arg(2), arg(3)), ty};
    }
    if (h == "and" || h == "or" || h == "xor") {
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      uint32_t b = operand(arg(3)).id;
      if (ty.k == Ty::Int && ty.boolean) {
        uint32_t op = h == "and" ? 167 : h == "or" ? 166 : 165;
        return {res(op, {tbool(), a, b}), ty};
      }
      uint32_t op = h == "and" ? 199 : h == "or" ? 197 : 198;
      return {res(op, {sty(ty), a, b}), ty};
    }
    if (h == "not") {
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      if (ty.k == Ty::Int && ty.boolean) return {res(168, {tbool(), a}), ty};
      return {canon(res(200, {sty(ty), a}), ty), ty};
    }
    if (h == "fadd" || h == "fsub" || h == "fmul" || h == "fdiv") {
      Ty ty = parse_type(arg(1));
      if (ty.k != Ty::Float) throw Refused(h + " on " + ty.kind_name());
      uint32_t a = operand(arg(2)).id;
      uint32_t b = operand(arg(3)).id;
      uint32_t op = h == "fadd" ? 129 : h == "fsub" ? 131 : h == "fmul" ? 133 : 136;
      return {res(op, {sty(ty), a, b}), ty};
    }
    if (h == "fneg") {
      Ty ty = parse_type(arg(1));
      if (ty.k != Ty::Float) throw Refused(std::string("fneg on ") + ty.kind_name());
      uint32_t a = operand(arg(2)).id;
      return {res(127, {sty(ty), a}), ty};
    }
    if (h == "iconv") {
      Ty ty = parse_type(arg(1));
      Opnd a = operand(arg(2));
      return {int_convert(ty, a.id, a.ty), ty};
    }
    if (h == "p2i") {
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      return {int_convert(ty, a, ty_ptr()), ty};
    }
    if (h == "i2p") {
      Opnd a = operand(arg(2));
      return {to_u64(a.id, a.ty), ty_ptr()};
    }
    if (h == "fconv") {
      Ty ty = parse_type(arg(1));
      Opnd a = operand(arg(2));
      if (a.ty.k != Ty::Float) throw BadIR(std::string("fconv of a ") + a.ty.kind_name());
      if (ty.size == a.ty.size) return {a.id, ty};
      return {res(115, {sty(ty), a.id}), ty};
    }
    if (h == "i2f" || h == "u2f") {
      Ty ty = parse_type(arg(1));
      if (ty.k != Ty::Float) throw Refused(h + " to " + ty.kind_name());
      Opnd a = operand(arg(2));
      if (a.ty.k == Ty::Int && a.ty.boolean) {
        a.id = bool_to_u32(a.id);
        a.ty = U32;
      }
      uint32_t v = h == "i2f" && a.ty.k == Ty::Int && a.ty.sign ? res(111, {sty(ty), a.id}) : res(112, {sty(ty), a.id});
      return {v, ty};
    }
    if (h == "cf2i") {
      Ty ty = parse_type(arg(1));
      Opnd a = operand(arg(2));
      return {float_to_int(ty, a.id, a.ty), ty};
    }
    static const char *const cmps[] = {"lt",   "le",   "gt",   "ge",   "eq",   "ne",   "lt.s", "le.s",
                                       "gt.s", "ge.s", "eq.s", "ne.s", "lt.u", "le.u", "gt.u", "ge.u",
                                       "eq.u", "ne.u", "lt.f", "le.f", "gt.f", "ge.f", "eq.f", "ne.f"};
    for (const char *c : cmps) {
      if (h != c) continue;
      std::string op = h.substr(0, 2);
      Ty ty = parse_type(arg(1));
      uint32_t a = operand(arg(2)).id;
      uint32_t b = operand(arg(3)).id;
      return {compare(op, ty, a, b), BOOL4};
    }
    if (h == "call") {
      auto r = call_expr(x);
      if (!r) throw Refused("value of a call of a void function");
      return *r;
    }
    if (h == "const") {
      parse_type(arg(1));
      return operand(x);
    }
    if (h == "null") return operand(x);
    throw Refused("expression " + (hp ? h : form_text(x)));
  }

  uint32_t to_i64(uint32_t id, const Ty &ty) {
    if (ty.k == Ty::Ptr || (ty.k == Ty::Int && ty.size == 8)) return id;
    return res(ty.sign ? 114 : 113, {t64(), id});
  }

  uint32_t compare(const std::string &op, const Ty &ty, uint32_t a, uint32_t b) {
    if (ty.k == Ty::Int && ty.boolean) {
      if (op != "eq" && op != "ne") throw Refused("bool comparison " + op);
      return res(op == "eq" ? 164 : 165, {tbool(), a, b});
    }
    if (ty.k == Ty::Float) {
      uint32_t code_ = op == "lt" ? 184 : op == "le" ? 188 : op == "gt" ? 186 : op == "ge" ? 190 : op == "eq" ? 180 : 183;
      return res(code_, {tbool(), a, b});
    }
    bool s = ty.k == Ty::Int && ty.sign;
    uint32_t code_ = op == "lt" ? (s ? 177 : 176) : op == "le" ? (s ? 179 : 178) : op == "gt" ? (s ? 173 : 172)
                   : op == "ge" ? (s ? 175 : 174) : op == "eq" ? 170 : 171;
    return res(code_, {tbool(), a, b});
  }

  uint32_t checked_div(const std::string &h, const Ty &ty, const Node &xa, const Node &xb) {
    if (!int_ty(ty)) throw Refused(h + " on " + ty.kind_name());
    uint32_t a = operand(xa).id;
    uint32_t b = operand(xb).id;
    uint32_t zero = int_const_of(ty, 0);
    uint32_t c;
    if (ty.sign) {
      int64_t minv = ty.size == 8 ? INT64_MIN : -(1ll << (ty.size * 8 - 1));
      uint32_t mn = int_const_of(ty, minv);
      uint32_t m1 = int_const_of(ty, -1);
      uint32_t c0 = res(170, {tbool(), b, zero});
      uint32_t q1 = res(170, {tbool(), b, m1});
      uint32_t q2 = res(170, {tbool(), a, mn});
      uint32_t q = res(167, {tbool(), q1, q2});
      c = res(166, {tbool(), c0, q});
    } else {
      c = res(170, {tbool(), b, zero});
    }
    trap_if(c, 1);
    uint32_t code_ = ty.sign ? (h == "cdiv" ? 135 : 138) : (h == "cdiv" ? 134 : 137);
    return canon(res(code_, {sty(ty), a, b}), ty);
  }

  uint32_t checked_shift(const std::string &h, const Ty &ty, const Node &xa, const Node &xb) {
    if (!int_ty(ty)) throw Refused(h + " on " + ty.kind_name());
    uint32_t a = operand(xa).id;
    Opnd c = operand(xb);
    if (!int_ty(c.ty)) throw Refused(std::string("shift count of type ") + c.ty.kind_name());
    int width = ty.size == 8 ? 64 : ty.size * 8;
    if (wide(c.ty)) trap_if(res(172, {tbool(), c.id, spv->c_u64(width)}), 2);
    else trap_if(res(172, {tbool(), c.id, spv->c_u32(width)}), 2);
    uint32_t cnt = c.id;
    if (wide(ty) && !wide(c.ty)) cnt = res(113, {t64(), cnt});
    else if (!wide(ty) && wide(c.ty)) cnt = res(113, {t32(), cnt});
    if (h == "cshl") return canon(res(196, {sty(ty), a, cnt}), ty);
    return canon(res(ty.sign ? 195 : 194, {sty(ty), a, cnt}), ty);
  }

  uint32_t int_convert(const Ty &ty, uint32_t a, const Ty &aty) {
    if (ty.k == Ty::Int && ty.boolean) {
      if (aty.k == Ty::Int && !aty.boolean) return res(170, {tbool(), a, zero_of(aty)});
      throw Refused("bool conversion");
    }
    if (ty.k != Ty::Int && ty.k != Ty::Ptr) throw Refused(std::string("iconv to ") + ty.kind_name());
    uint32_t src = aty.k == Ty::Int && aty.boolean ? bool_to_u32(a) : a;
    int sw = aty.k == Ty::Int && aty.boolean ? 4 : (aty.k == Ty::Ptr ? 8 : aty.size);
    bool sg = aty.k == Ty::Int && aty.sign && !aty.boolean;
    int dw = ty.k == Ty::Ptr ? 8 : ty.size;
    if (sw == 8 && dw == 8) return a;
    if (sw < 8 && dw == 8) return res(sg ? 114 : 113, {t64(), src});
    if (sw == 8 && dw < 8) {
      uint32_t v = res(113, {t32(), a});
      return canon(v, ty);
    }
    return canon(src, ty);
  }

  uint32_t float_to_int(const Ty &ty, uint32_t a, const Ty &aty) {
    if (!int_ty(ty)) throw Refused(std::string("cf2i to ") + ty.kind_name());
    if (aty.k != Ty::Float) throw BadIR(std::string("cf2i of a ") + aty.kind_name());
    int bits = ty.size * 8;
    int fbits = aty.size * 8;
    uint32_t lo_op;
    double lo_v, hi;
    if (ty.sign) {
      double lo = -std::ldexp(1.0, bits - 1);
      hi = std::ldexp(1.0, bits - 1);
      bool exact_below = (fbits == 64 && bits <= 53) || (fbits == 32 && bits <= 24);
      if (exact_below) {
        lo_op = 186;
        lo_v = lo - 1.0;
      } else {
        lo_op = 190;
        lo_v = lo;
      }
    } else {
      lo_op = 186;
      lo_v = -1.0;
      hi = std::ldexp(1.0, bits);
    }
    uint32_t lo_c = aty.size == 4 ? spv->c_float(32, lo_v) : spv->c_float(64, lo_v);
    uint32_t hi_c = aty.size == 4 ? spv->c_float(32, hi) : spv->c_float(64, hi);
    uint32_t p1 = res(lo_op, {tbool(), a, lo_c});
    uint32_t p2 = res(184, {tbool(), a, hi_c});
    uint32_t ok = res(167, {tbool(), p1, p2});
    trap_if(res(168, {tbool(), ok}), 6);
    uint32_t v = ty.sign ? res(110, {sty(ty), a}) : res(109, {sty(ty), a});
    return canon(v, ty);
  }

  // ---- calls and intrinsics

  std::vector<uint32_t> operand_ids(const std::vector<const Node *> &args) {
    std::vector<uint32_t> xs;
    for (const Node *a : args) xs.push_back(operand(*a).id);
    return xs;
  }

  std::optional<Opnd> call_expr(const Node &x) {
    parse_type(x.items.at(1));
    const Node &callee = x.items.at(2);
    if (!callee.is_sym('&')) throw Refused("indirect call");
    const std::string &nm = callee.text;
    std::vector<const Node *> args = drop(x, 3);
    auto xyz = [&](const std::string &n) { return (int)std::string("xyz").find(n.back()); };
    auto starts = [&](const char *p) { return nm.compare(0, std::strlen(p), p) == 0; };
    auto is3 = [&](const char *p) {
      std::string s(p);
      return nm == s + "x" || nm == s + "y" || nm == s + "z";
    };
    if (is3("__nfcxx_sycl_gid_")) return Opnd{global_comp(xyz(nm)), U32};
    if (is3("__nfcxx_sycl_lid_")) return Opnd{builtin_component(mod->lid, xyz(nm)), U32};
    if (is3("__nfcxx_sycl_group_")) return Opnd{group_comp(xyz(nm)), U32};
    if (is3("__nfcxx_sycl_grange_")) return Opnd{push_load(P_GX + xyz(nm)), U32};
    if (is3("__nfcxx_sycl_lrange_")) return Opnd{mod->spec[xyz(nm)], U32};
    if (nm == "__nfcxx_sycl_closure") return Opnd{push_load(P_CLOSURE), ty_ptr()};
    if (nm == "__nfcxx_sycl_local_base") return Opnd{local_base(), ty_ptr()};
    if (nm == "__nfcxx_sycl_scratch") {
      uint32_t lu = res(IADD, {t64(), local_base(), to_u64(push_load(P_LOCAL_USER), U32)});
      return Opnd{lu, ty_ptr()};
    }
    if (nm == "__nfcxx_sycl_sg_shuffle_u32" || nm == "__nfcxx_sycl_sg_shuffle_xor_u32") {
      if (!mod->kernel_cl) throw Refused(nm + ": sub-group shuffles need the OpenCL module (--kernel-cl)");
      mod->subgroup_used = true;
      sg_used = true;
      spv->cap(5568);
      spv->ext("SPV_INTEL_subgroups");
      uint32_t v = u32_of(operand(*args.at(0)).id, U32);
      uint32_t m = u32_of(operand(*args.at(1)).id, U32);
      uint32_t op = nm == "__nfcxx_sycl_sg_shuffle_xor_u32" ? 5574 : 5571;
      return Opnd{res(op, {t32(), v, m}), U32};
    }
    if (nm == "__nfcxx_sycl_barrier") {
      ins({224, spv->c_u32(SCOPE_WORKGROUP), spv->c_u32(SCOPE_WORKGROUP),
           spv->c_u32(mod->kernel_cl ? SEM_BARRIER_KERNEL : SEM_BARRIER)});
      return std::nullopt;
    }
    if (nm == "__nfcxx_sycl_sg_barrier") {
      if (mod->kernel_cl)
        ins({224, spv->c_u32(SCOPE_SUBGROUP), spv->c_u32(SCOPE_SUBGROUP), spv->c_u32(SEM_SG_BARRIER_KERNEL)});
      else
        ins({224, spv->c_u32(SCOPE_WORKGROUP), spv->c_u32(SCOPE_WORKGROUP), spv->c_u32(SEM_BARRIER)});
      return std::nullopt;
    }
    if (nm == "__nfcxx_sycl_fence") {
      uint32_t order = u32_of(operand(*args.at(0)).id, U32);
      uint32_t scope = u32_of(operand(*args.at(1)).id, U32);
      uint32_t spv_scope = res(130, {t32(), spv->c_u32(4), scope});
      uint32_t sh = res(196, {t32(), spv->c_u32(1), order});
      uint32_t is_relaxed = res(170, {tbool(), order, spv->c_u32(0)});
      uint32_t ord_bits = res(169, {t32(), is_relaxed, spv->c_u32(0), sh});
      uint32_t sem = res(197, {t32(), ord_bits, spv->c_u32(0x100 | 0x200)});
      ins({225, spv_scope, sem});
      return std::nullopt;
    }
    if (nm == "__nfcxx_sycl_fn1" || nm == "__nfcxx_sycl_fn1_f64" || nm == "__nfcxx_sycl_fn2" || nm == "__nfcxx_sycl_fn3") {
      const Node &op = *args.at(0);
      if (!head_is(op, "const")) throw Refused(nm + " with a non-constant operation");
      int64_t k = as_int(op.items.at(2));
      std::vector<Opnd> ops;
      for (size_t i = 1; i < args.size(); i++) ops.push_back(operand(*args[i]));
      std::vector<uint32_t> xs;
      for (auto &o : ops) xs.push_back(o.id);
      Ty fty = ops.at(0).ty;
      if (fty.k != Ty::Float) throw Refused(nm + " on a " + fty.kind_name());
      uint32_t ft = sty(fty);
      int g = glsl_of_math(k);
      if (k == 37) return Opnd{copysign_bits(xs.at(0), xs.at(1), fty), fty};
      if (!g && k == 36) {
        uint32_t q = res(136, {ft, xs.at(0), xs.at(1)});
        uint32_t t = res(12, {ft, spv->glsl_id(), spv->ext_num(3), q});
        return Opnd{res(131, {ft, xs[0], res(133, {ft, xs[1], t})}), fty};
      }
      if (!g) throw Refused(nm + " operation " + std::to_string(k));
      return Opnd{glsl_op(g, xs, ft), fty};
    }
    if (nm == "abs" || nm == "labs" || nm == "llabs") {
      Opnd a = operand(*args.at(0));
      uint32_t neg = res(ISUB, {sty(a.ty), zero_of(a.ty), a.id});
      uint32_t lt = res(177, {tbool(), a.id, zero_of(a.ty)});
      return Opnd{res(169, {sty(a.ty), lt, neg, a.id}), a.ty};
    }
    if (nm == "__nfcxx_sycl_atomic_load") {
      uint32_t p = atomic_ptr(*args.at(0));
      return Opnd{res(227, {t32(), p, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED)}), U32};
    }
    if (nm == "__nfcxx_sycl_atomic_cas") {
      uint32_t p = atomic_ptr(*args.at(0));
      uint32_t e = u32_of(operand(*args.at(1)).id, U32);
      uint32_t d = u32_of(operand(*args.at(2)).id, U32);
      return Opnd{res(230, {t32(), p, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), spv->c_u32(SEM_RELAXED), d, e}),
                  U32};
    }
    if (nm == "__nfcxx_sycl_atomic_fadd" || nm == "__nfcxx_sycl_atomic_fmin" || nm == "__nfcxx_sycl_atomic_fmax") {
      uint32_t p_addr = operand(*args.at(0)).id;
      uint32_t v = operand(*args.at(1)).id;
      float_atomic(p_addr, v, nm.back() == 'd' ? 0 : nm == "__nfcxx_sycl_atomic_fmin" ? 1 : 2);
      return Opnd{spv->c_float(32, 0.0), ty_float(4)};
    }
    static const std::map<std::string, uint32_t> atomic_codes = {{"add", 234}, {"max", 238}, {"min", 236},
                                                                 {"umax", 239}, {"umin", 237}, {"and", 240},
                                                                 {"or", 241},  {"xor", 242}, {"xchg", 229}};
    if (starts("__nfcxx_sycl_atomic_") && atomic_codes.count(nm.substr(20))) {
      uint32_t code_ = atomic_codes.at(nm.substr(20));
      uint32_t p = atomic_ptr(*args.at(0));
      uint32_t v = u32_of(operand(*args.at(1)).id, U32);
      return Opnd{res(code_, {t32(), p, spv->c_u32(SCOPE_DEVICE), spv->c_u32(SEM_RELAXED), v}), U32};
    }
    if (nm == "copysignf" || nm == "__builtin_copysignf") {
      auto xs = operand_ids(args);
      return Opnd{copysign_bits(xs.at(0), xs.at(1), ty_float(4)), ty_float(4)};
    }
    if (nm == "copysign" || nm == "__builtin_copysign") {
      auto xs = operand_ids(args);
      return Opnd{copysign_bits(xs.at(0), xs.at(1), ty_float(8)), ty_float(8)};
    }
    if (nm == "fmodf" || nm == "__builtin_fmodf") {
      auto xs = operand_ids(args);
      uint32_t ft = spv->t_float(32);
      uint32_t q = res(136, {ft, xs.at(0), xs.at(1)});
      uint32_t t = res(12, {ft, spv->glsl_id(), spv->ext_num(3), q});
      return Opnd{res(131, {ft, xs[0], res(133, {ft, xs[1], t})}), ty_float(4)};
    }
    if ((nm == "memcpy" || nm == "memmove" || nm == "__builtin_memcpy" || nm == "__builtin_memmove") && args.size() == 3 &&
        head_is(*args[2], "const")) {
      uint32_t d = operand(*args[0]).id;
      uint32_t sv = operand(*args[1]).id;
      copy_bytes(d, sv, as_int(args[2]->items.at(2)));
      return Opnd{d, ty_ptr()};
    }
    if ((nm == "memset" || nm == "__builtin_memset") && args.size() == 3 && head_is(*args[1], "const") &&
        head_is(*args[2], "const")) {
      uint32_t d = operand(*args[0]).id;
      int64_t byte = as_int(args[1]->items.at(2)) & 255;
      int64_t n = as_int(args[2]->items.at(2));
      counted_loop(n, 1, [&](uint32_t off) {
        uint32_t a = res(IADD, {t64(), d, off});
        uint32_t c = spv->c_u32(byte);
        mem_store(a, U8, c);
      });
      return Opnd{d, ty_ptr()};
    }
    if (int g = libm_glsl(nm)) {
      auto xs = operand_ids(args);
      uint32_t ft = spv->t_float(32);
      return Opnd{glsl_op(g, xs, ft), ty_float(4)};
    }
    if (starts("__nfcxx_")) throw Refused("unknown device intrinsic " + nm);
    // libstdc++'s assertion failure is noreturn (the host aborts): the device traps, as for an unreachable path
    if (nm == GLIBCXX_ASSERT_FAIL) {
      trap(5);
      check_dead_after_call();
      return std::nullopt;
    }
    auto &table = wgs_mode ? mod->fns_wgs : mod->fns;
    auto it = table.find(nm);
    SFn *callee_fn = it == table.end() ? nullptr : it->second;
    if (!callee_fn)
      throw Refused("call of " + nm + ", which has no body in the device unit (a host function, or a declaration)");
    if (args.size() != callee_fn->ptypes.size())
      throw Refused("call of " + nm + " with " + std::to_string(args.size()) + " arguments, it takes " +
                    std::to_string(callee_fn->ptypes.size()));
    auto xs = operand_ids(args);
    if (mod->kernel_cl) {
      xs.push_back(state(S_PUSH));
      xs.push_back(state(S_SP));
      xs.push_back(state(S_DEAD));
    }
    uint32_t rt = callee_fn->ret ? sty(*callee_fn->ret) : spv->t_void();
    if (!callee_fn->ret) {
      Inst c{57, rt, spv->id(), callee_fn->fid};
      c.insert(c.end(), xs.begin(), xs.end());
      ins(std::move(c));
      check_dead_after_call();
      return std::nullopt;
    }
    std::vector<uint32_t> l{rt, callee_fn->fid};
    l.insert(l.end(), xs.begin(), xs.end());
    uint32_t r = res_v(57, l);
    check_dead_after_call();
    return Opnd{r, *callee_fn->ret};
  }

  uint32_t atomic_ptr(const Node &x) {
    not_routed();
    uint32_t a = operand(x).id;
    return res(120, {spv->t_ptr(psb_sc(), t32()), a});
  }

  uint32_t copysign_bits(uint32_t x, uint32_t y, const Ty &fty) {
    if (fty.size == 4) {
      uint32_t ut = t32();
      uint32_t xb = res(124, {ut, x});
      uint32_t yb = res(124, {ut, y});
      uint32_t r = res(199, {ut, xb, spv->c_u32(0x7fffffff)});
      uint32_t sg = res(199, {ut, yb, spv->c_u32(0x80000000ll)});
      return res(124, {spv->t_float(32), res(197, {ut, r, sg})});
    }
    uint32_t ut = t64();
    uint32_t xb = res(124, {ut, x});
    uint32_t yb = res(124, {ut, y});
    uint32_t r = res(199, {ut, xb, spv->c_u64(0x7fffffffffffffffll)});
    uint32_t sg = res(199, {ut, yb, spv->c_u64((int64_t)0x8000000000000000ull)});
    return res(124, {spv->t_float(64), res(197, {ut, r, sg})});
  }

  uint32_t glsl_op(int g, const std::vector<uint32_t> &xs, uint32_t ft) {
    uint32_t i = spv->id();
    Inst v{12, ft, i, spv->glsl_id(), spv->ext_num(g)};
    v.insert(v.end(), xs.begin(), xs.end());
    ins(std::move(v));
    return i;
  }

  uint32_t local_base() {
    uint32_t lx = push_load(P_NX);
    uint32_t ly = push_load(P_NY);
    uint32_t wx = group_comp(0);
    uint32_t wy = group_comp(1);
    uint32_t wz = group_comp(2);
    t32();
    uint32_t lin = res(IADD, {t32(), res(IMUL, {t32(), res(IADD, {t32(), res(IMUL, {t32(), wz, ly}), wy}), lx}), wx});
    uint32_t stride = push_load(P_LOCAL_STRIDE);
    uint32_t off = res(IMUL, {t64(), to_u64(lin, U32), to_u64(stride, U32)});
    return res(IADD, {t64(), push_load(P_LOCAL), off});
  }

  // ---- statements

  void stmts(const std::vector<const Node *> &list) {
    for (size_t i = 0; i < list.size(); i++) {
      const Node &s = *list[i];
      const Node *nxt = i + 1 < list.size() ? list[i + 1] : nullptr;
      if ((head_is(s, "loop") || head_is(s, "switch")) && nxt && head_is(*nxt, "label"))
        pending_brk = to_s(nxt->items.at(1));
      else
        pending_brk.reset();
      stmt(s);
    }
  }

  std::optional<std::string> tail_label(const std::vector<const Node *> &list) {
    if (list.empty()) return std::nullopt;
    const Node &last = *list.back();
    if (head_is(last, "label")) return to_s(last.items.at(1));
    if (head_is(last, "block")) return tail_label(drop(last, 1));
    return std::nullopt;
  }

  void stmt(const Node &s) {
    if (s.kind != Node::List) throw BadIR("statement is not a form: " + form_text(s));
    const std::string *hp = head_of(s);
    std::string h = hp ? *hp : std::string();
    auto arg = [&](size_t i) -> const Node & { return s.items.at(i); };
    if (h == "block") {
      stmts(drop(s, 1));
    } else if (h == "let") {
      Ty ty = parse_type(arg(2));
      Opnd v = rval(arg(3));
      std::string key = to_s(arg(1));
      auto it = regs.find(key);
      uint32_t var;
      if (it == regs.end()) {
        uint32_t vv = var_decl(sty(ty));
        regs[key] = Reg{true, vv, ty};
        var = vv;
      } else {
        var = it->second.id;
      }
      ins({62, var, v.id});
    } else if (h == "set") {
      auto it = regs.find(to_s(arg(1)));
      if (it == regs.end()) throw BadIR("set of " + to_s(arg(1)) + " before its let");
      uint32_t var = it->second.id;
      uint32_t v = operand(arg(2)).id;
      ins({62, var, v});
    } else if (h == "store" || h == "store.v") {
      Ty ty = parse_type(arg(1));
      uint32_t v = operand(arg(3)).id;
      if (arg(2).is_sym('$') && locals.has(arg(2).text)) {
        Local *lv = locals.get(arg(2).text);
        if (!lv->var) lv->var = var_decl(sty(lv->ty));
        ins({62, lv->var, v});
      } else {
        uint32_t a = operand(arg(2)).id;
        mem_store(a, ty, v);
      }
    } else if (h == "if") {
      Opnd c = operand(arg(1));
      if (!(c.ty.k == Ty::Int && c.ty.boolean)) throw BadIR("if condition is not a bool");
      const Node *then_f = find_head(s, 2, "then");
      const Node *else_f = find_head(s, 2, "else");
      if (!then_f) throw BadIR("if without then");
      uint32_t t = new_label(), e = new_label(), m = new_label();
      ins({247, m, 0});
      cond_branch(c.id, t, e);
      label(t);
      stmts(drop(*then_f, 1));
      branch(m);
      label(e);
      if (else_f) stmts(drop(*else_f, 1));
      branch(m);
      label(m);
    } else if (h == "loop") {
      const Node *body_f = find_head(s, 1, "body");
      const Node *step_f = find_head(s, 1, "step");
      if (!body_f || !step_f) throw BadIR("loop without body and step");
      uint32_t hdr = new_label(), bodyl = new_label(), cont = new_label(), merge = new_label();
      auto brk = pending_brk;
      pending_brk.reset();
      if (brk) labels[*brk] = merge;
      auto end_label = tail_label(drop(*body_f, 1));
      if (end_label) labels[*end_label] = cont;
      uint32_t first = var_decl(t32());
      ins({62, first, spv->c_u32(1)});
      branch(hdr);
      label(hdr);
      ins({246, merge, cont, 0});
      branch(bodyl);
      loops.push_back({merge, cont});
      label(bodyl);
      uint32_t f = res(61, {t32(), first});
      uint32_t nf = res(170, {tbool(), f, spv->c_u32(0)});
      uint32_t run = new_label(), after = new_label();
      ins({247, after, 0});
      cond_branch(nf, run, after);
      label(run);
      if (step_f->items.size() > 1) stmts(drop(*step_f, 1));
      branch(after);
      label(after);
      ins({62, first, spv->c_u32(0)});
      stmts(drop(*body_f, 1));
      loops.pop_back();
      branch(cont);
      label(cont);
      branch(hdr);
      label(merge);
    } else if (h == "switch") {
      switch_stmt(s);
    } else if (h == "break") {
      if (loops.empty()) throw Refused("break outside a loop or switch");
      branch(loops.back().brk);
    } else if (h == "continue") {
      const Loop *enc = nullptr;
      for (auto it = loops.rbegin(); it != loops.rend(); ++it)
        if (it->cont) {
          enc = &*it;
          break;
        }
      if (!enc) throw BadIR("continue outside a loop");
      branch(enc->cont);
    } else if (h == "goto") {
      std::string l = s.items.size() > 1 ? to_s(s.items[1]) : std::string();
      auto it = labels.find(l);
      if (it == labels.end())
        throw Refused("goto \"" + l + "\" (not the end of a loop body or the label after a loop or switch)");
      branch(it->second);
    } else if (h == "label") {
    } else if (h == "trap" || h == "unreachable") {
      trap(5);
    } else if (h == "bounds") {
      Opnd v = operand(arg(1));
      uint32_t n = is_reg(arg(2)) ? operand(arg(2)).id : int_const_of(v.ty, as_int(arg(2)));
      uint32_t vi = wide(v.ty) ? v.id : u32_of(v.id, v.ty);
      trap_if(res(172, {tbool(), vi, n}), 3);
    } else if (h == "nonnull") {
      // the address of a function is never null (the front end's check on a function pointer that is a template argument)
      if (!arg(1).is_sym('&')) {
        uint32_t p = operand(arg(1)).id;
        trap_if(res(170, {tbool(), p, spv->c_u64(0)}), 4);
      }
    } else if (h == "return") {
      if (!ret) {
        if (s.items.size() > 1) throw Refused("return with a value in a void function");
        emit_return(std::nullopt);
      } else {
        if (s.items.size() != 2) throw Refused("return without a value in " + name);
        uint32_t v = operand(arg(1)).id;
        emit_return(v);
      }
    } else if (h == "eval") {
      if (!(s.items.size() == 2 && head_is(s.items[1], "call")))
        throw Refused("eval of " + (s.items.size() > 1 ? form_text(s.items[1]) : std::string()));
      call_expr(s.items[1]);
    } else if (h == "copy") {
      int64_t n = as_int(arg(1));
      uint32_t d = operand(arg(2)).id;
      uint32_t src = operand(arg(3)).id;
      copy_bytes(d, src, n);
    } else {
      throw Refused("statement " + (hp ? h : form_text(s)));
    }
  }

  void counted_loop(int64_t n, int64_t step, const std::function<void(uint32_t)> &yield) {
    uint32_t i = var_decl(t64());
    ins({62, i, spv->c_u64(0)});
    uint32_t hdr = new_label(), bodyl = new_label(), cont = new_label(), merge = new_label();
    branch(hdr);
    label(hdr);
    uint32_t iv = res(61, {t64(), i});
    uint32_t c = res(176, {tbool(), iv, spv->c_u64(n)});
    ins({246, merge, cont, 0});
    cond_branch(c, bodyl, merge);
    label(bodyl);
    yield(iv);
    branch(cont);
    label(cont);
    uint32_t iv2 = res(61, {t64(), i});
    uint32_t nx = res(IADD, {t64(), iv2, spv->c_u64(step)});
    ins({62, i, nx});
    branch(hdr);
    label(merge);
  }

  void copy_bytes(uint32_t d, uint32_t src, int64_t n) {
    const Ty t = n % 4 == 0 ? U32 : U8;
    counted_loop(n, n % 4 == 0 ? 4 : 1, [&](uint32_t off) {
      uint32_t v = mem_load(res(IADD, {t64(), src, off}), t);
      mem_store(res(IADD, {t64(), d, off}), t, v);
    });
  }

  static bool jump(const Node &s) {
    const std::string *hp = head_of(s);
    std::string h = hp ? *hp : std::string();
    if (h == "break" || h == "continue" || h == "return" || h == "unreachable" || h == "trap" || h == "goto") return true;
    if (h == "block") return s.items.size() > 1 && jump(s.items.back());
    if (h == "if") {
      const Node *t = find_head(s, 2, "then");
      const Node *e = find_head(s, 2, "else");
      return t && e && t->items.size() > 1 && e->items.size() > 1 && jump(t->items.back()) && jump(e->items.back());
    }
    return false;
  }

  void switch_stmt(const Node &s) {
    auto brk = pending_brk;
    pending_brk.reset();
    const Node *body_f = find_head(s, 1, "body");
    if (!body_f) throw BadIR("switch without body");
    Opnd v = operand(s.items.at(1));
    if (!int_ty(v.ty)) throw Refused(std::string("switch on a ") + v.ty.kind_name());
    if (v.ty.size > 4) throw Refused("switch on a " + std::to_string(v.ty.size) + "-byte integer");
    std::vector<const Node *> items;
    std::function<void(const Node &)> expand = [&](const Node &f) {
      if (head_is(f, "block")) {
        for (size_t i = 1; i < f.items.size(); i++) expand(f.items[i]);
      } else {
        items.push_back(&f);
      }
    };
    for (size_t i = 1; i < body_f->items.size(); i++) expand(body_f->items[i]);
    struct Arm {
      std::vector<int64_t> lits;
      bool dflt = false;
      std::vector<const Node *> body;
      uint32_t label;
    };
    std::vector<Arm> arms;
    Arm *cur = nullptr;
    for (const Node *it : items) {
      if (head_is(*it, "case") || head_is(*it, "default")) {
        if (!cur || !cur->body.empty()) {
          arms.push_back(Arm{{}, false, {}, new_label()});
          cur = &arms.back();
        }
        if (head_is(*it, "case")) cur->lits.push_back(as_int(it->items.at(1).items.at(2)));
        else cur->dflt = true;
      } else {
        if (!cur) throw Refused("statement before the first case of a switch");
        cur->body.push_back(it);
      }
    }
    for (size_t i = 0; i < arms.size(); i++) {
      if (i == arms.size() - 1 || arms[i].body.empty()) continue;
      if (!jump(*arms[i].body.back())) throw Refused("switch arm falls through into the next one");
    }
    uint32_t merge = new_label();
    uint32_t dflt_label = merge;
    for (auto &a : arms)
      if (a.dflt) {
        dflt_label = a.label;
        break;
      }
    ins({247, merge, 0});
    uint32_t sel = u32_of(v.id, v.ty);
    Inst sw{251, sel, dflt_label};
    // the Ruby's arm labels list keeps the case values and the default in their order; the pairs skip the default
    for (auto &a : arms)
      for (int64_t lit : a.lits) {
        sw.push_back((uint32_t)(lit & 0xffffffff));
        sw.push_back(a.label);
      }
    term(std::move(sw));
    loops.push_back({merge, 0});
    if (brk) labels[*brk] = merge;
    for (size_t i = 0; i < arms.size(); i++) {
      label(arms[i].label);
      stmts(arms[i].body);
      uint32_t nxt = i + 1 < arms.size() ? arms[i + 1].label : merge;
      branch(nxt);
    }
    loops.pop_back();
    label(merge);
  }

  // ---- the function

  void compile() {
    uint32_t rt = ret ? sty(*ret) : spv->t_void();
    for (size_t k = 0; k < ptypes.size(); k++) param_ids.push_back(spv->id());
    for (size_t k = 0; k < ptypes.size(); k++) regs["%" + std::to_string(k)] = Reg{false, param_ids[k], ptypes[k]};
    if (mod->kernel_cl) {
      uint32_t a = spv->t_ptr(SC_CROSSWG, mod->push_struct_type());
      uint32_t b = spv->t_ptr(SC_FUNCTION, t64());
      uint32_t c = spv->t_ptr(SC_FUNCTION, t32());
      state_types = {a, b, c};
      for (int k = 0; k < 3; k++) state_param_ids.push_back(spv->id());
      has_state = true;
      st_push = state_param_ids[0];
      st_sp = state_param_ids[1];
      st_dead = state_param_ids[2];
    }
    std::vector<uint32_t> ps;
    for (auto &t : ptypes) ps.push_back(sty(t));
    ps.insert(ps.end(), state_types.begin(), state_types.end());
    ftype = spv->t_fn(rt, ps);
    ret_t = rt;
    if (frame > 0) {
      oldsp_var = var_decl(t64());
      frame_var = var_decl(t64());
      uint32_t old = res(61, {t64(), state(S_SP)});
      ins({62, oldsp_var, old});
      uint32_t fr = res(IADD, {t64(), old, spv->c_u64(-frame)});
      fr = res(199, {t64(), fr, spv->c_u64((int64_t)0xfffffffffffffff0ull)});
      ins({62, frame_var, fr});
      ins({62, state(S_SP), fr});
    }
    for (auto &k : locals.keys) {
      Local *lv = locals.get(k);
      if (!lv->var) lv->var = var_decl(sty(lv->ty));
    }
    std::vector<const Node *> b(body.begin(), body.end());
    stmts(b);
    if (!term_) {
      if (!ret) {
        emit_return(std::nullopt);
      } else {
        uint32_t z = zero_of(*ret);
        emit_return(z);
      }
    }
  }

  std::vector<Inst> function_text() {
    std::vector<Inst> out;
    out.push_back({54, ret_t, fid, 0, ftype});
    for (size_t k = 0; k < ptypes.size(); k++) out.push_back({55, sty(ptypes[k]), param_ids[k]});
    for (size_t k = 0; k < state_types.size(); k++) out.push_back({55, state_types[k], state_param_ids[k]});
    uint32_t lab = spv->id();
    out.push_back({248, lab});
    for (auto &v : vars) out.push_back(v);
    for (auto &c : code) out.push_back(c);
    out.push_back({56});
    return out;
  }

  // The entry of a kernel: sets this invocation's stack and the dead flag, then calls the kernel's IR function.
  void compile_wrapper(uint32_t ir_fn) {
    if (mod->kernel_cl) {
      uint32_t push_p = spv->id();
      uint32_t tv = spv->t_void();
      uint32_t pp = spv->t_ptr(SC_CROSSWG, mod->push_struct_type());
      ftype = spv->t_fn(tv, {pp});
      uint32_t pp2 = spv->t_ptr(SC_CROSSWG, mod->push_struct_type());
      param_lines.push_back({55, pp2, push_p});
      uint32_t sp_v = var_decl(t64());
      uint32_t dead_v = var_decl(t32());
      has_state = true;
      st_push = push_p;
      st_sp = sp_v;
      st_dead = dead_v;
    } else {
      uint32_t tv = spv->t_void();
      ftype = spv->t_fn(tv, {});
    }
    ret_t = spv->t_void();
    t32();
    t64();
    uint32_t wlin = res(IADD, {t32(), res(IMUL, {t32(), res(IADD, {t32(), res(IMUL, {t32(), group_comp(2), push_load(P_NY)}),
                                                                    group_comp(1)}),
                                                 push_load(P_NX)}),
                                group_comp(0)});
    uint32_t lsx = mod->spec[0];
    uint32_t lsy = mod->spec[1];
    uint32_t llin =
        res(IADD, {t32(), res(IMUL, {t32(), res(IADD, {t32(), res(IMUL, {t32(), builtin_component(mod->lid, 2), lsy}),
                                                        builtin_component(mod->lid, 1)}),
                                     lsx}),
                   builtin_component(mod->lid, 0)});
    uint32_t inv = res(IMUL, {t32(), res(IMUL, {t32(), lsx, lsy}), mod->spec[2]});
    uint32_t lin = res(IADD, {t32(), res(IMUL, {t32(), wlin, inv}), llin});
    uint32_t sbytes = to_u64(push_load(P_STACK_BYTES), U32);
    uint32_t base = push_load(P_STACK);
    uint32_t off = res(IMUL, {t64(), to_u64(lin, U32), sbytes});
    uint32_t top = res(IADD, {t64(), base, res(IADD, {t64(), off, sbytes})});
    ins({62, state(S_DEAD), spv->c_u32(0)});
    ins({62, state(S_SP), top});
    Inst c{57, spv->t_void(), spv->id(), ir_fn};
    if (has_state) {
      c.push_back(state(S_PUSH));
      c.push_back(state(S_SP));
      c.push_back(state(S_DEAD));
    }
    ins(std::move(c));
    term({253});
  }
};

}  // namespace

// ------------------------------------------------------------------ the module

Emitted emit_module(const std::string &src, bool kernel_cl) {
  std::vector<Node> forms = read_forms(src);
  Mod mod;
  std::unordered_map<std::string, int64_t> sizes;
  for (Node &f : forms) {
    const std::string *h = head_of(f);
    if (!h) continue;
    if (*h == "function") mod.defs.set(to_s(f.items.at(1)), &f);
    else if (*h == "abi-type") {
      sizes[to_s(f.items.at(1))] = as_int(f.items.at(2));
      if (f.items.size() > 4 && head_is(f.items[4], "empty")) mod.empty_types.insert(to_s(f.items[1]));
    } else if (*h == "global") mod.globals.set(to_s(f.items.at(1)), &f);
    else if (*h == "data") mod.datas.set(to_s(f.items.at(1)), &f);
  }
  std::vector<std::string> entries;
  for (auto &n : mod.defs.keys)
    if (n.find("__nfcxx_sycl_entry_") != std::string::npos) entries.push_back(n);
  Emitted out;
  if (entries.empty()) return out;
  // the array constructor calls of a reachable function are unrolled before its callees are taken
  std::vector<std::string> order;
  std::unordered_map<std::string, int> vstate;   // 1 open, 2 done
  std::function<void(const std::string &)> visit = [&](const std::string &name) {
    int &st = vstate[name];
    if (st == 2) return;
    if (st == 1) throw Refused("recursive call of " + name);
    st = 1;
    Node *f = *mod.defs.get(name);
    expand_cxa_vec_ctor(*f);
    std::vector<std::string> calls;
    collect_calls(*f, calls);
    std::unordered_set<std::string> seen;
    for (auto &c : calls)
      if (mod.defs.has(c) && seen.insert(c).second) visit(c);
    vstate[name] = 2;
    order.push_back(name);
  };
  for (auto &e : entries) visit(e);

  Spv spv;
  spv.kernel_cl = kernel_cl;
  if (kernel_cl) {
    spv.cap(4);
    spv.cap(6);
    spv.cap(11);
  } else {
    spv.cap(1);
    spv.cap(11);
    spv.cap(5347);
    spv.cap(5345);
    spv.cap(5346);
    spv.ext("SPV_KHR_physical_storage_buffer");
  }
  spv.glsl_id();
  SpvModule smod(&spv, kernel_cl);
  smod.irmod = &mod;

  // the reach of a function over a call relation (the calls, or every address of a function)
  auto reach_by = [&](const std::string &root, bool refs, std::unordered_map<std::string, std::vector<std::string>> &edges) {
    std::unordered_set<std::string> seen;
    std::vector<std::string> stack{root}, outv;
    while (!stack.empty()) {
      std::string n = stack.back();
      stack.pop_back();
      if (seen.count(n) || !mod.defs.has(n)) continue;
      seen.insert(n);
      outv.push_back(n);
      auto it = edges.find(n);
      if (it == edges.end()) {
        std::vector<std::string> acc, sel;
        if (refs) collect_fn_refs(**mod.defs.get(n), acc);
        else collect_calls(**mod.defs.get(n), acc);
        for (auto &c : acc)
          if (mod.defs.has(c)) sel.push_back(c);
        it = edges.emplace(n, std::move(sel)).first;
      }
      stack.insert(stack.end(), it->second.begin(), it->second.end());
    }
    return outv;
  };
  if (kernel_cl) {
    // the layout runs before the functions' setup folds constexpr function-pointer slots into direct calls, so its reach
    // follows every address of a function, not only the calls
    std::unordered_map<std::string, std::vector<std::string>> ref_edges;
    std::vector<std::unordered_set<std::string>> groups;
    for (auto &e : entries) {
      auto r = reach_by(e, true, ref_edges);
      groups.emplace_back(r.begin(), r.end());
    }
    // wgs_layout: a function's statics start after those of the functions placed before it that a kernel reaches with it
    OMap<std::vector<std::tuple<std::string, int64_t, int64_t>>> slots;
    for (auto &fname : mod.defs.keys) {
      Node *form = *mod.defs.get(fname);
      for (Node &f : form->items) {
        if (!(head_is(f, "slot") && f.items.size() == 5 && head_is(f.items[2], "struct") && mentions_wgs(f.items[2])))
          continue;
        std::vector<std::tuple<std::string, int64_t, int64_t>> *l = slots.get(fname);
        if (!l) l = &slots.set(fname, {});
        l->emplace_back(to_s(f.items[1]), as_int(f.items[3]), std::max<int64_t>(as_int(f.items[4]), 16));
      }
    }
    std::unordered_map<std::string, int64_t> ends;
    int64_t total = 0;
    for (auto &fname : slots.keys) {
      int64_t off = 0;
      for (auto &g : groups) {
        if (!g.count(fname)) continue;
        for (auto &n : g) {
          auto it = ends.find(n);
          if (it != ends.end()) off = std::max(off, it->second);
        }
      }
      for (auto &[sname, size, align] : *slots.get(fname)) {
        off = (off + align - 1) / align * align;
        smod.wgs[{fname, sname}] = off;
        off += size;
      }
      ends[fname] = off;
      total = std::max(total, off);
    }
    smod.has_wgs = true;
    smod.wgs_total = (total + 15) / 16 * 16;
    if (smod.wgs_total > 0) smod.wgs_var = spv.wgs_var((uint32_t)(smod.wgs_total / 4));
  }
  std::vector<std::unique_ptr<SFn>> owned;
  std::unordered_map<std::string, SFn *> fns;
  for (auto &n : order) {
    uint32_t id = spv.id();
    owned.push_back(std::make_unique<SFn>(*mod.defs.get(n), id, &smod));
    fns[n] = owned.back().get();
  }
  smod.fns = fns;
  // clones for the work-group-static kernels (each compiles from its own copy of the IR)
  std::unordered_set<std::string> static_names;
  for (auto &kv : smod.wgs) static_names.insert(kv.first.first);
  std::unordered_map<std::string, std::vector<std::string>> call_edges;   // after the originals' setup
  std::unordered_map<std::string, std::vector<std::string>> reach_of;
  for (auto &e : entries) reach_of[e] = reach_by(e, false, call_edges);
  std::vector<std::string> static_entries;
  std::unordered_set<std::string> static_entry_set, clone_set;
  for (auto &e : entries) {
    bool any = false;
    for (auto &n : reach_of[e])
      if (static_names.count(n)) any = true;
    if (any) {
      static_entries.push_back(e);
      static_entry_set.insert(e);
      for (auto &n : reach_of[e]) clone_set.insert(n);
    }
  }
  std::vector<std::string> clone_order;
  for (auto &n : order)
    if (clone_set.count(n)) clone_order.push_back(n);
  std::vector<std::unique_ptr<Node>> copies;
  for (auto &n : clone_order) {
    copies.push_back(std::make_unique<Node>(copy_form(**mod.defs.get(n))));
    uint32_t id = spv.id();
    owned.push_back(std::make_unique<SFn>(copies.back().get(), id, &smod, true));
    smod.fns_wgs[n] = owned.back().get();
  }
  // the stack: the deepest chain of frames from a kernel, with slack for alignment
  std::unordered_map<std::string, int64_t> depth;
  std::function<int64_t(const std::string &)> depth_of = [&](const std::string &name) -> int64_t {
    auto it = depth.find(name);
    if (it != depth.end()) return it->second;
    auto f = fns.find(name);
    if (f == fns.end()) throw std::runtime_error("undefined method `frame' for nil (" + name + ")");
    int64_t m = 0;
    bool any = false;
    for (auto &c : f->second->callees) {
      int64_t d = depth_of(c);
      if (!any || d > m) m = d;
      any = true;
    }
    int64_t d = f->second->frame + m;
    depth[name] = d;
    return d;
  };
  int64_t maxd = 0;
  for (size_t i = 0; i < entries.size(); i++) {
    int64_t d = depth_of(entries[i]);
    if (i == 0 || d > maxd) maxd = d;
  }
  int64_t stack_bytes = (maxd + 16 + 15) / 16 * 16;
  smod.stack_bytes = stack_bytes;
  std::unordered_set<std::string> orig_needed;
  for (auto &e : entries)
    if (!static_entry_set.count(e))
      for (auto &n : reach_of[e]) orig_needed.insert(n);
  auto compile_in = [&](const std::string &n, SFn *fn) {
    try {
      fn->compile();
    } catch (Refused &e) {
      throw Refused(e.text + " (in " + n + ")");
    }
  };
  for (auto &n : order)
    if (orig_needed.count(n)) compile_in(n, fns[n]);
  for (auto &n : clone_order) compile_in(n, smod.fns_wgs[n]);
  for (auto &n : order) {
    if (!orig_needed.count(n)) continue;
    for (auto &inst : fns[n]->function_text()) spv.func(inst);
  }
  for (auto &n : clone_order)
    for (auto &inst : smod.fns_wgs[n]->function_text()) spv.func(inst);
  std::vector<uint32_t> iface = kernel_cl ? std::vector<uint32_t>{smod.gid, smod.lid, smod.wid}
                                          : std::vector<uint32_t>{smod.gid, smod.lid, smod.wid, smod.sp, smod.dead, smod.push};
  for (size_t k = 0; k < entries.size(); k++) {
    const std::string &e = entries[k];
    SFn *f = smod.fns_wgs.count(e) ? smod.fns_wgs[e] : fns[e];
    if (!f->ptypes.empty()) throw Refused("kernel " + e + " takes parameters");
    std::string key, strukt;
    if (!kernel_key(**mod.defs.get(e), key, strukt))
      throw Refused("kernel " + e + ": cannot find the closure type (no cast of __nfcxx_sycl_closure())");
    uint32_t wid = spv.id();
    SFn wr(nullptr, wid, &smod);
    wr.compile_wrapper(f->fid);
    spv.func({54, spv.t_void(), wr.fid, 0, wr.ftype});
    for (auto &inst : wr.param_lines) spv.func(inst);
    spv.func({248, spv.id()});
    for (auto &inst : wr.vars) spv.func(inst);
    for (auto &inst : wr.code) spv.func(inst);
    spv.func({56});
    spv.add_entry(kernel_cl ? 6 : 5, wr.fid, "k" + std::to_string(k), iface);
    bool sg = false;
    for (auto &n : reach_of[e]) {
      auto &table = static_entry_set.count(e) ? smod.fns_wgs : fns;
      auto it = table.find(n);
      if (it != table.end() && it->second->sg_used) sg = true;
    }
    if (sg) {
      spv.cap(58);
      spv.entry_mode(wr.fid, 35, SUBGROUP_SIZE);
    }
    auto sz = sizes.find(strukt);
    out.manifest.push_back("k" + std::to_string(k) + "\t" + key + "\t" + std::to_string(sz == sizes.end() ? 0 : sz->second) +
                           (sg ? "\t" + std::to_string(SUBGROUP_SIZE) : std::string()));
  }
  if (mod.statics.size() > 0 || !mod.static_order.empty()) {
    std::vector<uint8_t> bytes;
    std::vector<std::pair<int64_t, int64_t>> relocs;
    mod.static_image(bytes, relocs);
    static const char hx[] = "0123456789abcdef";
    std::string line = "S\t" + std::to_string(mod.static_size) + "\t";
    line.reserve(line.size() + bytes.size() * 2);
    for (uint8_t b : bytes) {
      line += hx[b >> 4];
      line += hx[b & 15];
    }
    out.manifest.push_back(line);
    for (auto &[o, t] : relocs) out.manifest.push_back("R\t" + std::to_string(o) + "\t" + std::to_string(t));
  }
  if (smod.wgs_total > 0) out.manifest.push_back("L\t" + std::to_string(smod.wgs_total));
  out.manifest.push_back("T\t" + std::to_string(stack_bytes));
  out.words = spv.finish(kernel_cl ? 0x00010200 : 0x00010500);
  out.has_module = true;
  return out;
}
