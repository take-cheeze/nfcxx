// WGSL rendering of UOp graphs (see nfcuop_wgsl.hpp).
#include "nfcuop_wgsl.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>

namespace nfcuop {
namespace {

constexpr int64_t kWorkgroup = 64;

// A Float32 literal that reads back as the same float. WGSL float literals need a '.' or an exponent.
std::string f32_literal(double v) {
  if (!std::isfinite(v)) throw Error("render_wgsl: a non-finite constant has no WGSL literal here");
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.9g", v);
  std::string s = buf;
  if (s.find_first_of(".e") == std::string::npos) s += ".0";
  return s;
}

std::string u32(int64_t v) { return std::to_string(v) + "u"; }

// Row-major strides of a shape.
std::vector<int64_t> strides_of(const Shape& s) {
  std::vector<int64_t> st(s.size(), 1);
  for (size_t a = s.size(); a-- > 1;) st[a - 1] = st[a] * s[a];
  return st;
}

const char* alu_expr(Op op) {
  switch (op) {
    case Op::Neg: return "-(%0)";
    case Op::Sqrt: return "sqrt(%0)";
    case Op::Add: return "(%0 + %1)";
    case Op::Sub: return "(%0 - %1)";
    case Op::Mul: return "(%0 * %1)";
    case Op::FDiv: return "(%0 / %1)";
    case Op::Max: return "max(%0, %1)";
    default: return nullptr;
  }
}

// Replaces %0, %1, ... in `tmpl` with the arguments.
std::string subst(const char* tmpl, const std::vector<std::string>& args) {
  std::string out;
  for (const char* p = tmpl; *p; ++p) {
    if (*p == '%' && p[1] >= '0' && p[1] <= '9') {
      out += args.at(static_cast<size_t>(p[1] - '0'));
      ++p;
    } else {
      out += *p;
    }
  }
  return out;
}

}  // namespace

WgslProgram render_wgsl(const UOp* root) {
  if (root->is_const() || root->op == Op::Var) throw Error("render_wgsl: the root must be an operation");
  WgslProgram prog;
  prog.shape = root->shape;

  // Buffer of each node that has one (Var and kernel nodes); Const nodes are literals.
  std::map<const UOp*, size_t> buf_of;
  std::set<std::string> input_names;
  std::vector<const UOp*> order = toposort(root);

  for (const UOp* u : order) {
    if (u->dtype != DType::Float32) throw Error("render_wgsl: only Float32 is rendered");
    if (u->is_const()) {
      if (!std::isfinite(u->value.f)) throw Error("render_wgsl: a non-finite constant has no WGSL literal here");
      continue;
    }
    if (u->op == Op::Var) {
      if (!input_names.insert(u->name).second) throw Error("render_wgsl: two inputs named " + u->name);
      buf_of[u] = prog.buffers.size();
      prog.buffers.push_back({u->name, numel(u->shape), true});
      continue;
    }
    if (u->op != Op::ReduceSum && !alu_expr(u->op)) {
      throw Error(std::string("render_wgsl: ") + name(u->op) + " is not rendered (node " + std::to_string(u->id) + ")");
    }
    if (numel(u->shape) == 0) throw Error("render_wgsl: an empty tensor has no WGSL buffer");
    buf_of[u] = prog.buffers.size();
    prog.buffers.push_back({"b" + std::to_string(u->id), numel(u->shape), false});
  }

  // The WGSL expression that reads element `idx` (a u32 expression) of a node, or the literal of a Const.
  auto read = [&](const UOp* s, const std::string& idx) -> std::string {
    if (s->is_const()) return f32_literal(s->value.f);
    return prog.buffers[buf_of.at(s)].name + "[" + idx + "]";
  };

  std::string src;
  for (size_t b = 0; b < prog.buffers.size(); ++b) {
    const WgslBuffer& buf = prog.buffers[b];
    src += "@group(0) @binding(" + std::to_string(b) + ") var<storage, " + (buf.input ? "read" : "read_write") +
           "> " + buf.name + ": array<f32>;\n";
  }
  src += "\n";

  for (const UOp* u : order) {
    if (u->is_const() || u->op == Op::Var) continue;
    const std::string entry = "k" + std::to_string(u->id);
    const std::string out = prog.buffers[buf_of.at(u)].name;
    const int64_t count = numel(u->shape);
    src += "@compute @workgroup_size(" + std::to_string(kWorkgroup) + ")\n";
    src += "fn " + entry + "(@builtin(global_invocation_id) gid: vec3<u32>) {\n";
    src += "  let i = gid.x;\n";
    src += "  if (i >= " + u32(count) + ") { return; }\n";

    if (u->op == Op::ReduceSum) {
      // Output coordinates of the non-reduced axes come from i; the reduced axes are loop variables, outermost first,
      // so the loops visit the source in row-major order.
      const UOp* x = u->src[0];
      const Shape& xs = x->shape;
      const Shape& axes = u->arg;
      std::set<int64_t> reduced(axes.begin(), axes.end());
      std::vector<int64_t> xst = strides_of(xs), ost = strides_of(u->shape);
      // The source index of the element at the given loop variables: a non-reduced axis is a coordinate of i, a reduced
      // axis is its loop variable (or 0u for the first element).
      auto source_index = [&](bool first) {
        std::string s;
        for (size_t a = 0; a < xs.size(); ++a) {
          std::string c = !reduced.count(static_cast<int64_t>(a)) ? "((i / " + u32(ost[a]) + ") % " + u32(u->shape[a]) + ")"
                          : first                                  ? "0u"
                                                                   : "r" + std::to_string(a);
          s += (a ? " + " : "") + c + " * " + u32(xst[a]);
        }
        return s.empty() ? std::string("0u") : s;
      };
      std::string loop_open, loop_close, first_test;
      for (size_t a = 0; a < xs.size(); ++a) {
        if (!reduced.count(static_cast<int64_t>(a))) continue;
        std::string r = "r" + std::to_string(a);
        loop_open += "  for (var " + r + ": u32 = 0u; " + r + " < " + u32(xs[a]) + "; " + r + " = " + r + " + 1u) {\n";
        loop_close = "  }\n" + loop_close;
        first_test += (first_test.empty() ? "" : " || ") + r + " != 0u";
      }
      // The first element of the reduced axes starts the sum; the loops then add the others in row-major order,
      // skipping the first element, which is already in acc.
      src += "  var acc: f32 = " + read(x, "(" + source_index(true) + ")") + ";\n";
      src += loop_open;
      if (!first_test.empty()) {
        src += "    if (" + first_test + ") { acc = acc + " + read(x, "(" + source_index(false) + ")") + "; }\n";
      }
      src += loop_close;
      src += "  " + out + "[i] = acc;\n";
    } else {
      std::vector<std::string> args;
      for (const UOp* s : u->src) args.push_back(read(s, "i"));
      src += "  " + out + "[i] = " + subst(alu_expr(u->op), args) + ";\n";
    }
    src += "}\n\n";
    std::vector<size_t> bindings;
    for (const UOp* s : u->src) {
      if (s->is_const()) continue;
      size_t b = buf_of.at(s);
      if (std::find(bindings.begin(), bindings.end(), b) == bindings.end()) bindings.push_back(b);
    }
    bindings.push_back(buf_of.at(u));
    prog.kernels.push_back({entry, buf_of.at(u), count, bindings});
  }

  prog.output = buf_of.at(root);
  prog.source = src;
  return prog;
}

}  // namespace nfcuop
