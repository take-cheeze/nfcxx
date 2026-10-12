// nfcuop C rendering. See nfcuop_cgen.hpp.
#include "nfcuop_cgen.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

namespace nfcuop {

namespace {

const char* ctype(DType d) {
  switch (d) {
    case DType::Bool: return "uint8_t";
    case DType::Int32: return "int32_t";
    case DType::Int64: return "int64_t";
    case DType::Float32: return "float";
    case DType::Float64: return "double";
  }
  return "?";
}
const char* utype(DType d) { return d == DType::Int64 ? "uint64_t" : "uint32_t"; }  // for wrapping integer arithmetic
const char* sfx(DType d) {
  switch (d) {
    case DType::Bool: return "u8";
    case DType::Int32: return "i32";
    case DType::Int64: return "i64";
    case DType::Float32: return "f32";
    case DType::Float64: return "f64";
  }
  return "?";
}

std::string lit(const Scalar& s) {
  char buf[96];
  switch (s.dtype) {
    case DType::Bool: return s.i ? "((uint8_t)1)" : "((uint8_t)0)";
    case DType::Int32:
      if (s.i == INT32_MIN) return "(-2147483647 - 1)";
      return "((int32_t)" + std::to_string(s.i) + ")";
    case DType::Int64:
      if (s.i == INT64_MIN) return "(-9223372036854775807LL - 1)";
      return "((int64_t)" + std::to_string(s.i) + "LL)";
    case DType::Float32:
    case DType::Float64: {
      const char* t = s.dtype == DType::Float32 ? "float" : "double";
      if (std::isnan(s.f)) return std::string("((") + t + ")NAN)";
      if (std::isinf(s.f)) return std::string("((") + t + ")" + (s.f < 0 ? "-INFINITY" : "INFINITY") + ")";
      std::snprintf(buf, sizeof buf, "%a", s.f);  // exact: a hexadecimal float
      return std::string("((") + t + ")" + buf + ")";
    }
  }
  return "0";
}

bool atomic(const std::string& e) {
  if (e.empty()) return false;
  for (char c : e) if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_')) return false;
  return true;
}

// The row-major strides of a shape.
std::vector<int64_t> strides_of(const Shape& s) {
  std::vector<int64_t> st(s.size(), 1);
  for (size_t k = s.size(); k-- > 1;) st[k - 1] = st[k] * s[k];
  return st;
}

// The statements a kernel needs before it stores (index temporaries).
struct KGen {
  std::vector<std::string> stmts;
  int tmp = 0;
  std::string bind(const std::string& e) {
    if (atomic(e)) return e;
    std::string n = "t" + std::to_string(tmp++);
    stmts.push_back("const int64_t " + n + " = " + e + ";");
    return n;
  }
};

using Idx = std::vector<std::string>;  // one C expression per dimension; "0" for a dimension of size 1

std::string flat(const Idx& idx, const Shape& shape) {
  std::vector<int64_t> st = strides_of(shape);
  std::string out;
  for (size_t k = 0; k < shape.size(); k++) {
    if (shape[k] == 1 || idx[k] == "0") continue;
    std::string term = st[k] == 1 ? idx[k] : "(" + idx[k] + ") * " + std::to_string(st[k]);
    out += (out.empty() ? "" : " + ") + term;
  }
  return out.empty() ? "0" : out;
}

// the C expression of a binary ALU op on already rendered operands
std::string alu2(Op op, DType dt, const std::string& a, const std::string& b) {
  const std::string T = ctype(dt);
  const bool fl = is_float(dt);
  switch (op) {
    case Op::Add: case Op::Sub: case Op::Mul: {
      const char* sym = op == Op::Add ? "+" : op == Op::Sub ? "-" : "*";
      if (fl) return "((" + T + ")(" + a + " " + sym + " " + b + "))";
      const std::string U = utype(dt);
      return "((" + T + ")((" + U + ")(" + a + ") " + sym + " (" + U + ")(" + b + ")))";
    }
    case Op::Max:
      return std::string("nfc_max_") + sfx(dt) + "(" + a + ", " + b + ")";
    case Op::FDiv: return "((" + T + ")(" + a + " / " + b + "))";
    case Op::IDiv: return std::string("nfc_idiv_") + sfx(dt) + "(" + a + ", " + b + ")";
    case Op::Mod: return std::string("nfc_mod_") + sfx(dt) + "(" + a + ", " + b + ")";
    case Op::And: return "((" + T + ")((" + a + ") & (" + b + ")))";
    case Op::Or: return "((" + T + ")((" + a + ") | (" + b + ")))";
    case Op::Xor: return "((" + T + ")((" + a + ") ^ (" + b + ")))";
    default: break;
  }
  throw Error(std::string("render_c: no C for ") + name(op));
}

class Renderer {
 public:
  CProgram run(const std::vector<const UOp*>& roots);

 private:
  std::vector<const UOp*> order_;
  std::unordered_map<const UOp*, int> uses_;
  std::unordered_set<const UOp*> real_;
  std::unordered_map<const UOp*, std::string> buf_;   // realized node -> C pointer name
  std::map<std::string, int> in_index_;
  std::vector<CInput> inputs_;
  std::ostringstream body_;
  CProgram prog_;

  bool cheap(const UOp* n) const {
    if (n->op == Op::Const || n->op == Op::Var) return true;
    if (is_movement(n->op)) return real_.count(n->src[0]) || cheap(n->src[0]);
    return false;
  }
  std::string elem(const UOp* n, const Idx& idx, KGen& g);
  std::string elem_op(const UOp* n, const Idx& idx, KGen& g);
  std::string movement(const UOp* n, const Idx& idx, KGen& g);
  std::string cast(const UOp* n, const std::string& a);
  void kernel(const UOp* n, const std::string& out, const char* ctype_name);
};

std::string Renderer::cast(const UOp* n, const std::string& a) {
  const DType to = n->dtype, from = n->src[0]->dtype;
  const std::string T = ctype(to);
  if (to == from) return a;
  if (to == DType::Bool) return "((uint8_t)((" + a + ") != 0))";
  if (is_float(from)) {
    if (to == DType::Int32) return "nfc_f2i32((double)(" + a + "))";
    if (to == DType::Int64) return "nfc_f2i64((double)(" + a + "))";
    return "((" + T + ")(" + a + "))";
  }
  if (to == DType::Int32 && from == DType::Int64) return "nfc_wrap32(" + a + ")";
  return "((" + T + ")(" + a + "))";
}

std::string Renderer::elem(const UOp* n, const Idx& idx, KGen& g) {
  if (real_.count(n)) return buf_.at(n) + "[" + flat(idx, n->shape) + "]";
  return elem_op(n, idx, g);
}

std::string Renderer::movement(const UOp* n, const Idx& idx, KGen& g) {
  const UOp* src = n->src[0];
  const size_t r = src->shape.size();
  Idx s(r, "0");
  switch (n->op) {
    case Op::Reshape: {
      std::vector<std::pair<size_t, int64_t>> a, b;  // the dimensions above 1, in order
      for (size_t k = 0; k < n->shape.size(); k++) if (n->shape[k] > 1) a.push_back({k, n->shape[k]});
      for (size_t k = 0; k < r; k++) if (src->shape[k] > 1) b.push_back({k, src->shape[k]});
      bool same = a.size() == b.size();
      for (size_t k = 0; same && k < a.size(); k++) same = a[k].second == b[k].second;
      if (same) {  // only size-1 dimensions came or went: indices carry over
        for (size_t k = 0; k < a.size(); k++) s[b[k].first] = idx[a[k].first];
      } else {
        std::string f = g.bind(flat(idx, n->shape));
        std::vector<int64_t> st = strides_of(src->shape);
        for (size_t k = 0; k < r; k++) {
          if (src->shape[k] == 1) continue;
          std::string e = "(" + f + " / " + std::to_string(st[k]) + ")";
          if (k > 0) e = "(" + e + " % " + std::to_string(src->shape[k]) + ")";
          s[k] = g.bind(e);
        }
      }
      break;
    }
    case Op::Permute:
      for (size_t k = 0; k < r; k++) s[static_cast<size_t>(n->arg[k])] = idx[k];
      break;
    case Op::Expand:
      for (size_t k = 0; k < r; k++) s[k] = src->shape[k] == 1 ? "0" : idx[k];
      break;
    case Op::Shrink:
      for (size_t k = 0; k < r; k++) s[k] = n->arg[k] == 0 ? idx[k] : g.bind("(" + idx[k] + " + " + std::to_string(n->arg[k]) + ")");
      break;
    case Op::Flip:
      s = idx;
      for (int64_t ax : n->arg)
        if (src->shape[ax] > 1) s[static_cast<size_t>(ax)] = g.bind("(" + std::to_string(src->shape[ax] - 1) + " - " + idx[ax] + ")");
      break;
    case Op::Pad: {
      std::string cond;
      for (size_t k = 0; k < r; k++) {
        int64_t before = n->arg[k], after = n->arg[r + k];
        if (before == 0 && after == 0) { s[k] = idx[k]; continue; }
        std::string c = "(" + idx[k] + " >= " + std::to_string(before) + " && " + idx[k] + " < " + std::to_string(before + src->shape[k]) + ")";
        cond += (cond.empty() ? "" : " && ") + c;
        s[k] = before == 0 ? idx[k] : g.bind("(" + idx[k] + " - " + std::to_string(before) + ")");
      }
      return "((" + cond + ") ? " + elem(src, s, g) + " : " + lit(Scalar::from_int(n->dtype, 0)) + ")";
    }
    default: break;
  }
  return elem(src, s, g);
}

std::string Renderer::elem_op(const UOp* n, const Idx& idx, KGen& g) {
  const DType dt = n->dtype;
  const std::string T = ctype(dt);
  if (n->op == Op::Const) return lit(n->value);
  if (n->op == Op::Var) return "in_" + std::to_string(in_index_.at(n->name)) + "[" + flat(idx, n->shape) + "]";
  if (is_movement(n->op)) return movement(n, idx, g);
  if (is_reduce(n->op)) throw Error("render_c: a reduction must be materialized");
  auto S = [&](size_t k) { return elem(n->src[k], idx, g); };
  switch (n->op) {
    case Op::Neg:
      if (is_float(dt)) return "((" + T + ")(-" + S(0) + "))";
      return "((" + T + ")((" + utype(dt) + ")0 - (" + utype(dt) + ")(" + S(0) + ")))";
    case Op::Sqrt: case Op::Exp2: case Op::Log2: case Op::Sin: {
      const char* f = n->op == Op::Sqrt ? "sqrt" : n->op == Op::Exp2 ? "exp2" : n->op == Op::Log2 ? "log2" : "sin";
      return "((" + T + ")" + f + "((double)(" + S(0) + ")))";  // in double, rounded, like the interpreter
    }
    case Op::CmpLt: { std::string a = S(0), b = S(1); return "((uint8_t)((" + a + ") < (" + b + ")))"; }
    case Op::CmpNe: { std::string a = S(0), b = S(1); return "((uint8_t)((" + a + ") != (" + b + ")))"; }
    case Op::Where: { std::string c = S(0), a = S(1), b = S(2); return "((" + c + ") ? (" + a + ") : (" + b + "))"; }
    case Op::Cast: return cast(n, S(0));
    default: { std::string a = S(0), b = S(1); return alu2(n->op, n->src[0]->dtype, a, b); }
  }
}

void Renderer::kernel(const UOp* n, const std::string& out, const char*) {
  const Shape& shape = n->shape;
  std::ostringstream& o = body_;
  o << "  { /* " << name(n->op) << " " << name(n->dtype) << to_string(shape) << " */\n";
  Idx idx(shape.size(), "0");
  int depth = 2;
  auto pad = [&](int d) { return std::string(static_cast<size_t>(d) * 2, ' '); };
  for (size_t k = 0; k < shape.size(); k++) {
    if (shape[k] == 1) continue;
    idx[k] = "i" + std::to_string(k);
    o << pad(depth++) << "for (int64_t " << idx[k] << " = 0; " << idx[k] << " < " << shape[k] << "; " << idx[k] << "++) {\n";
  }
  const std::string store = out + "[" + flat(idx, shape) + "]";
  if (!is_reduce(n->op)) {
    KGen g;
    std::string v = elem_op(n, idx, g);
    for (const std::string& s : g.stmts) o << pad(depth) << s << "\n";
    o << pad(depth) << store << " = " << v << ";\n";
  } else {
    const UOp* src = n->src[0];
    const std::string T = ctype(n->dtype);
    Idx sidx = idx;
    std::vector<size_t> loops;
    for (int64_t ax : n->arg) {
      sidx[static_cast<size_t>(ax)] = src->shape[ax] > 1 ? "r" + std::to_string(ax) : "0";
      if (src->shape[ax] > 1) loops.push_back(static_cast<size_t>(ax));
    }
    KGen g;
    std::string v = elem(src, sidx, g);
    o << pad(depth) << "{ " << T << " acc = 0; int first = 1;\n";
    int d2 = depth + 1;
    for (size_t ax : loops) o << pad(d2++) << "for (int64_t r" << ax << " = 0; r" << ax << " < " << src->shape[ax] << "; r" << ax << "++) {\n";
    for (const std::string& s : g.stmts) o << pad(d2) << s << "\n";
    o << pad(d2) << T << " v = " << v << ";\n";
    o << pad(d2) << "if (first) { acc = v; first = 0; } else acc = "
      << alu2(n->op == Op::ReduceSum ? Op::Add : Op::Max, n->dtype, "acc", "v") << ";\n";
    for (size_t k = 0; k < loops.size(); k++) o << pad(--d2) << "}\n";
    o << pad(depth) << store << " = acc; }\n";
  }
  for (size_t k = 0; k < shape.size(); k++) if (shape[k] != 1) o << pad(--depth) << "}\n";
  o << "  }\n";
  prog_.kernels++;
}

CProgram Renderer::run(const std::vector<const UOp*>& roots) {
  if (roots.empty()) throw Error("render_c: no outputs");
  // the nodes, sources first, each once
  std::unordered_set<const UOp*> seen;
  for (const UOp* r : roots)
    for (const UOp* u : toposort(r))
      if (seen.insert(u).second) order_.push_back(u);
  for (const UOp* u : order_) for (const UOp* s : u->src) uses_[s]++;
  std::unordered_set<const UOp*> is_root(roots.begin(), roots.end());
  for (const UOp* r : roots) uses_[r]++;
  // inputs
  std::map<std::string, const UOp*> vars;
  for (const UOp* u : order_)
    if (u->op == Op::Var) {
      auto it = vars.find(u->name);
      if (it != vars.end() && it->second != u) throw Error("render_c: two variables named " + u->name + " differ in dtype or shape");
      vars[u->name] = u;
    }
  for (const auto& kv : vars) {
    in_index_[kv.first] = static_cast<int>(inputs_.size());
    inputs_.push_back(CInput{kv.first, kv.second->dtype, kv.second->shape});
  }
  // what is stored in a buffer
  for (const UOp* u : order_) {
    if (u->op == Op::Const || u->op == Op::Var) {
      if (is_root.count(u)) real_.insert(u);  // an output that is a leaf is copied into its output buffer
      continue;
    }
    if (is_root.count(u) || is_reduce(u->op) || (uses_[u] > 1 && !cheap(u))) real_.insert(u);
  }
  // buffers: outputs first (a repeated root is a copy of its first occurrence), then temporaries
  std::unordered_map<const UOp*, int> out_slot;
  std::vector<std::pair<const UOp*, int>> dup;  // (root, output index) that copy another output
  for (size_t k = 0; k < roots.size(); k++) {
    prog_.outputs.push_back(COutput{roots[k]->dtype, roots[k]->shape});
    if (!out_slot.count(roots[k])) out_slot[roots[k]] = static_cast<int>(k);
    else dup.push_back({roots[k], static_cast<int>(k)});
  }
  std::ostringstream decl, release;
  int tmps = 0;
  for (const UOp* u : order_) {
    if (!real_.count(u)) continue;
    if (u->op == Op::Const || u->op == Op::Var) { /* output copies only */ }
    auto os = out_slot.find(u);
    if (os != out_slot.end()) {
      buf_[u] = "o" + std::to_string(os->second);
    } else {
      buf_[u] = "tmp" + std::to_string(tmps);
      decl << "  " << ctype(u->dtype) << "* tmp" << tmps << " = (" << ctype(u->dtype) << "*)malloc(sizeof(" << ctype(u->dtype) << ") * "
           << numel(u->shape) << "); if (!tmp" << tmps << ") rc = 1;\n";
      release << "  free(tmp" << tmps << ");\n";
      tmps++;
    }
  }
  prog_.temporaries = tmps;
  // kernels in order; a leaf output is a copy
  for (const UOp* u : order_) {
    if (!real_.count(u)) continue;
    if (u->op == Op::Const || u->op == Op::Var) {
      // elem_op of a leaf is the leaf itself
    }
    kernel(u, buf_.at(u), "");
  }
  for (const auto& d : dup) {  // an output given twice
    const std::string from = buf_.at(d.first), to = "o" + std::to_string(d.second);
    body_ << "  memcpy(" << to << ", " << from << ", sizeof(" << ctype(d.first->dtype) << ") * " << numel(d.first->shape) << ");\n";
  }
  std::ostringstream src;
  src << "/* generated by nfcuop (render_c): " << prog_.kernels << " loop nest(s), " << tmps << " temporary buffer(s) */\n"
      << "#include <stdint.h>\n#include <stdlib.h>\n#include <string.h>\n#include <math.h>\n\n"
      << "static inline int32_t nfc_max_i32(int32_t a, int32_t b) { return a > b ? a : b; }\n"
      << "static inline int64_t nfc_max_i64(int64_t a, int64_t b) { return a > b ? a : b; }\n"
      << "static inline float nfc_max_f32(float a, float b) { return a != a ? b : b != b ? a : a > b ? a : b; }\n"
      << "static inline double nfc_max_f64(double a, double b) { return a != a ? b : b != b ? a : a > b ? a : b; }\n"
      << "static inline uint8_t nfc_max_u8(uint8_t a, uint8_t b) { return a > b ? a : b; }\n"
      << "static inline int32_t nfc_idiv_i32(int32_t a, int32_t b) { return b == 0 ? 0 : b == -1 ? (int32_t)((uint32_t)0 - (uint32_t)a) : a / b; }\n"
      << "static inline int64_t nfc_idiv_i64(int64_t a, int64_t b) { return b == 0 ? 0 : b == -1 ? (int64_t)((uint64_t)0 - (uint64_t)a) : a / b; }\n"
      << "static inline int32_t nfc_mod_i32(int32_t a, int32_t b) { return (b == 0 || b == -1) ? 0 : a % b; }\n"
      << "static inline int64_t nfc_mod_i64(int64_t a, int64_t b) { return (b == 0 || b == -1) ? 0 : a % b; }\n"
      << "static inline int32_t nfc_wrap32(int64_t v) { return (int32_t)(uint32_t)(uint64_t)v; }\n"
      << "static inline int32_t nfc_f2i32(double v) { if (v != v) return 0; if (v >= 2147483647.0) return INT32_MAX; if (v <= -2147483648.0) return INT32_MIN; return (int32_t)v; }\n"
      << "static inline int64_t nfc_f2i64(double v) { if (v != v) return 0; if (v >= 9223372036854775808.0) return INT64_MAX; if (v <= -9223372036854775808.0) return INT64_MIN; return (int64_t)v; }\n\n"
      << "int nfcuop_run(const void* const* in, void* const* out) {\n  int rc = 0;\n";
  for (size_t k = 0; k < inputs_.size(); k++)
    src << "  const " << ctype(inputs_[k].dtype) << "* in_" << k << " = (const " << ctype(inputs_[k].dtype) << "*)in[" << k << "];  /* " << inputs_[k].name << " */\n";
  for (size_t k = 0; k < roots.size(); k++) src << "  " << ctype(roots[k]->dtype) << "* o" << k << " = (" << ctype(roots[k]->dtype) << "*)out[" << k << "];\n";
  src << decl.str() << "  if (rc) goto done;\n" << body_.str() << "done:\n" << release.str() << "  return rc;\n}\n";
  prog_.source = src.str();
  prog_.inputs = inputs_;
  return prog_;
}

}  // namespace

CProgram render_c(const std::vector<const UOp*>& roots) {
  Renderer r;
  return r.run(roots);
}

// ---- compiling and running ----

namespace {

std::string read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

}  // namespace

std::shared_ptr<CModule> CModule::compile(const CProgram& p, const std::string& cc_in) {
  std::string cc = cc_in;
  if (cc.empty()) {
    const char* env = std::getenv("NFCUOP_CC");
    cc = env && *env ? env : "cc";
  }
  const char* tmpdir = std::getenv("TMPDIR");
  std::string tmpl = std::string(tmpdir && *tmpdir ? tmpdir : "/tmp") + "/nfcuop-XXXXXX";
  std::vector<char> dir(tmpl.begin(), tmpl.end());
  dir.push_back(0);
  if (!mkdtemp(dir.data())) throw Error("CModule: cannot create a temporary directory");
  const std::string d = dir.data(), c = d + "/prog.c", so = d + "/prog.so", log = d + "/log.txt";
  { std::ofstream f(c); f << p.source; }
  const bool plain = cc.find("nfcxx") != std::string::npos;  // the nfcxx driver takes -shared and -o; the gcc/clang flags are for cc
  std::string cmd = cc + (plain ? " -shared" : " -O2 -shared -fPIC -ffp-contract=off -fwrapv") + " -o " + so + " " + c + (plain ? "" : " -lm") + " > " + log + " 2>&1";
  int rc = std::system(cmd.c_str());
  std::string output = read_file(log);
  auto cleanup = [&] { unlink(c.c_str()); unlink(so.c_str()); unlink(log.c_str()); rmdir(d.c_str()); };
  if (rc != 0) {
    cleanup();
    throw Error("CModule: compiling the generated C failed (" + cc + "):\n" + output);
  }
  void* h = dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
  std::string err = h ? "" : dlerror();
  cleanup();
  if (!h) throw Error("CModule: dlopen failed: " + err);
  auto fn = reinterpret_cast<int (*)(const void* const*, void* const*)>(dlsym(h, "nfcuop_run"));
  if (!fn) { dlclose(h); throw Error("CModule: nfcuop_run not found"); }
  std::shared_ptr<CModule> m(new CModule());
  m->prog_ = p;
  m->handle_ = h;
  m->fn_ = fn;
  return m;
}

CModule::~CModule() {
  if (handle_) dlclose(handle_);
}

namespace {

// raw storage of an Array in the C types
std::vector<unsigned char> to_raw(const Array& a) {
  size_t sz = a.dtype == DType::Bool ? 1 : (a.dtype == DType::Int32 || a.dtype == DType::Float32) ? 4 : 8;
  std::vector<unsigned char> raw(sz * a.data.size() + 8);  // never empty
  for (size_t k = 0; k < a.data.size(); k++) {
    const Scalar& s = a.data[k];
    unsigned char* p = raw.data() + k * sz;
    switch (a.dtype) {
      case DType::Bool: *p = s.i ? 1 : 0; break;
      case DType::Int32: { int32_t v = static_cast<int32_t>(s.i); std::memcpy(p, &v, 4); break; }
      case DType::Int64: { int64_t v = s.i; std::memcpy(p, &v, 8); break; }
      case DType::Float32: { float v = static_cast<float>(s.f); std::memcpy(p, &v, 4); break; }
      case DType::Float64: { double v = s.f; std::memcpy(p, &v, 8); break; }
    }
  }
  return raw;
}

Array from_raw(DType d, const Shape& shape, const unsigned char* raw) {
  Array a;
  a.dtype = d;
  a.shape = shape;
  size_t sz = d == DType::Bool ? 1 : (d == DType::Int32 || d == DType::Float32) ? 4 : 8;
  for (int64_t k = 0; k < numel(shape); k++) {
    const unsigned char* p = raw + static_cast<size_t>(k) * sz;
    switch (d) {
      case DType::Bool: a.data.push_back(Scalar::from_int(d, *p != 0)); break;
      case DType::Int32: { int32_t v; std::memcpy(&v, p, 4); a.data.push_back(Scalar::from_int(d, v)); break; }
      case DType::Int64: { int64_t v; std::memcpy(&v, p, 8); a.data.push_back(Scalar::from_int(d, v)); break; }
      case DType::Float32: { float v; std::memcpy(&v, p, 4); a.data.push_back(Scalar::from_double(d, v)); break; }
      case DType::Float64: { double v; std::memcpy(&v, p, 8); a.data.push_back(Scalar::from_double(d, v)); break; }
    }
  }
  return a;
}

}  // namespace

std::vector<Array> CModule::run(const std::map<std::string, Array>& feeds) const {
  std::vector<std::vector<unsigned char>> in_raw, out_raw;
  std::vector<const void*> in_ptr;
  for (const CInput& in : prog_.inputs) {
    auto it = feeds.find(in.name);
    if (it == feeds.end()) throw Error("CModule: no value for input " + in.name);
    if (it->second.dtype != in.dtype || it->second.shape != in.shape)
      throw Error("CModule: input " + in.name + " is " + name(in.dtype) + to_string(in.shape) + ", given " + name(it->second.dtype) + to_string(it->second.shape));
    in_raw.push_back(to_raw(it->second));
    in_ptr.push_back(in_raw.back().data());
  }
  std::vector<void*> out_ptr;
  for (const COutput& o : prog_.outputs) {
    size_t sz = o.dtype == DType::Bool ? 1 : (o.dtype == DType::Int32 || o.dtype == DType::Float32) ? 4 : 8;
    out_raw.emplace_back(sz * static_cast<size_t>(numel(o.shape)) + 8);
    out_ptr.push_back(out_raw.back().data());
  }
  if (fn_(in_ptr.data(), out_ptr.data()) != 0) throw Error("CModule: the generated code failed to allocate memory");
  std::vector<Array> out;
  for (size_t k = 0; k < prog_.outputs.size(); k++) out.push_back(from_raw(prog_.outputs[k].dtype, prog_.outputs[k].shape, out_raw[k].data()));
  return out;
}

}  // namespace nfcuop
