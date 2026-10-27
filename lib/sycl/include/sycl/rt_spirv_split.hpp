// The module of one kernel from an image's SPIR-V (rt_level_zero.hpp, rt_opencl.hpp). An image holds every kernel of its
// source (ggml-sycl's flash-attention instances: ~150, 11-25 MB of SPIR-V), and the driver compiles a whole module at once:
// a 32-lane tile image took ~16 minutes per local size. The module of an entry point keeps the module's capabilities,
// extensions, imports and memory model, that entry point and its execution modes, the functions it reaches (OpFunctionCall)
// and the declarations and decorations those use, so the driver compiles one kernel. Ids keep their numbers (the bound is the
// image's). An operand word counts as an id unless the opcode makes it a literal (the opcodes scripts/pathb-spirv-emit.rb
// emits; another opcode's words all count, which can only keep more).
#ifndef NFCXX_SYCL_RT_SPIRV_SPLIT_HPP
#define NFCXX_SYCL_RT_SPIRV_SPLIT_HPP

#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace sycl {
namespace detail {

// the module of entry point `entry` of the SPIR-V in il (n bytes), or an empty vector when there is no such entry point
inline std::vector<uint32_t> spirv_entry_module(const uint8_t *il, size_t n, const std::string &entry) {
  std::vector<uint32_t> w(n / 4);
  std::memcpy(w.data(), il, w.size() * 4);
  if (w.size() < 5 || w[0] != 0x07230203u) return {};
  struct Inst {
    size_t at;
    uint32_t op, wc;
  };
  std::vector<Inst> ins;
  for (size_t i = 5; i < w.size();) {
    uint32_t wc = w[i] >> 16, op = w[i] & 0xffff;
    if (wc == 0 || i + wc > w.size()) return {};
    ins.push_back({i, op, wc});
    i += wc;
  }
  enum : uint32_t { OP_EXT_INST_IMPORT = 11, OP_ENTRY_POINT = 15, OP_EXEC_MODE = 16, OP_DECORATE = 71, OP_MEMBER_DECORATE = 72,
                    OP_FUNCTION = 54, OP_FUNCTION_END = 56, OP_FUNCTION_CALL = 57 };
  // the entry point: its function and interface
  uint32_t fid = 0;
  size_t entry_inst = 0;
  for (size_t k = 0; k < ins.size() && !fid; k++) {
    if (ins[k].op != OP_ENTRY_POINT) continue;
    const char *name = reinterpret_cast<const char *>(&w[ins[k].at + 3]);
    size_t maxlen = (ins[k].wc - 3) * 4;
    if (strnlen(name, maxlen) == entry.size() && std::memcmp(name, entry.data(), entry.size()) == 0) {
      fid = w[ins[k].at + 2];
      entry_inst = k;
    }
  }
  if (!fid) return {};
  // where each function is (first and last instruction) and each global declaration (by result id)
  std::unordered_map<uint32_t, std::pair<size_t, size_t>> fns;
  std::unordered_map<uint32_t, size_t> decl;
  std::vector<uint32_t> result_of(ins.size(), 0);   // the result id of each global declaration (0: none)
  size_t first_fn = ins.size();
  for (size_t k = 0; k < ins.size(); k++) {
    const Inst &x = ins[k];
    if (x.op == OP_FUNCTION) {
      if (first_fn == ins.size()) first_fn = k;
      size_t e = k;
      while (e < ins.size() && ins[e].op != OP_FUNCTION_END) e++;
      fns[w[x.at + 2]] = {k, e};
      k = e;
      continue;
    }
    // types (result in word 1) and constants and variables (type in word 1, result in word 2)
    if (x.op == OP_EXT_INST_IMPORT || (x.op >= 19 && x.op <= 39)) result_of[k] = w[x.at + 1];
    else if ((x.op >= 41 && x.op <= 52) || x.op == 59) result_of[k] = w[x.at + 2];
    if (result_of[k]) decl[result_of[k]] = k;
  }
  // the operand words of an instruction that are ids (from word 1)
  auto ids_of = [&](const Inst &x, std::vector<uint32_t> &out) {
    const uint32_t *p = &w[x.at];
    uint32_t wc = x.wc, op = x.op;
    auto all = [&](uint32_t from, uint32_t to) {
      for (uint32_t i = from; i < to && i < wc; i++) out.push_back(p[i]);
    };
    switch (op) {
      case 21: case 22: return;                                    // OpTypeInt, OpTypeFloat: literals
      case 23: all(2, 3); return;                                  // OpTypeVector: the component type, a literal count
      case 32: all(3, 4); return;                                  // OpTypePointer: a literal storage class, the type
      case 43: case 50: all(1, 2); return;                         // OpConstant, OpSpecConstant: the type, literal values
      case 59: all(1, 2); all(4, 5); return;                       // OpVariable: the type, a literal class, the initializer
      case 54: all(1, 2); all(4, 5); return;                       // OpFunction: the result type, a literal control, the type
      case 61: all(1, 2); all(3, 4); return;                       // OpLoad: memory operands are literals
      case 62: all(1, 3); return;                                  // OpStore
      case 81: all(1, 2); all(3, 4); return;                       // OpCompositeExtract: literal indices
      case 12: all(1, 2); all(3, 4); all(5, wc); return;           // OpExtInst: a literal instruction number
      case 246: all(1, 3); return;                                 // OpLoopMerge: literal loop control
      case 247: all(1, 2); return;                                 // OpSelectionMerge: literal selection control
      case 250: all(1, 4); return;                                 // OpBranchConditional: literal weights
      case 251:                                                    // OpSwitch: selector, default, (literal, label) pairs
        all(1, 3);
        for (uint32_t i = 4; i < wc; i += 2) out.push_back(p[i]);
        return;
      default: all(1, wc); return;
    }
  };
  // the functions the entry reaches
  std::vector<uint32_t> fn_work{fid};
  std::unordered_map<uint32_t, bool> live_fn;
  while (!fn_work.empty()) {
    uint32_t f = fn_work.back();
    fn_work.pop_back();
    auto it = fns.find(f);
    if (it == fns.end() || live_fn[f]) continue;
    live_fn[f] = true;
    for (size_t k = it->second.first; k <= it->second.second && k < ins.size(); k++)
      if (ins[k].op == OP_FUNCTION_CALL) fn_work.push_back(w[ins[k].at + 3]);
  }
  // the ids they use, and the declarations those use in turn
  std::vector<uint32_t> work;
  {
    // the interface ids follow the name (a nul-terminated string in words: the last word has a zero byte)
    const Inst &e = ins[entry_inst];
    uint32_t i = 3;
    while (i < e.wc) {
      uint32_t word = w[e.at + i];
      i++;
      if ((word & 0xff000000u) == 0 || (word & 0x00ff0000u) == 0 || (word & 0x0000ff00u) == 0 || (word & 0xffu) == 0) break;
    }
    for (; i < e.wc; i++) work.push_back(w[e.at + i]);
  }
  for (auto &f : fns) {
    if (!live_fn.count(f.first) || !live_fn[f.first]) continue;
    for (size_t k = f.second.first; k <= f.second.second && k < ins.size(); k++) ids_of(ins[k], work);
  }
  std::unordered_map<uint32_t, bool> live;
  while (!work.empty()) {
    uint32_t id = work.back();
    work.pop_back();
    if (live[id]) continue;
    live[id] = true;
    auto d = decl.find(id);
    if (d != decl.end()) ids_of(ins[d->second], work);
  }
  // the module: the image's header and preamble, this entry point, and what is live, in the image's order
  std::vector<uint32_t> out(w.begin(), w.begin() + 5);
  auto put = [&](const Inst &x) { out.insert(out.end(), w.begin() + x.at, w.begin() + x.at + x.wc); };
  for (size_t k = 0; k < ins.size(); k++) {
    const Inst &x = ins[k];
    if (k >= first_fn) {
      if (x.op == OP_FUNCTION) {
        auto it = fns.find(w[x.at + 2]);
        size_t e = it->second.second;
        if (live_fn.count(w[x.at + 2]) && live_fn[w[x.at + 2]])
          for (size_t j = k; j <= e; j++) put(ins[j]);
        k = e;
      }
      continue;
    }
    switch (x.op) {
      case OP_ENTRY_POINT:
        if (k == entry_inst) put(x);
        break;
      case OP_EXEC_MODE:
        if (w[x.at + 1] == fid) put(x);
        break;
      case 5: case 6: case OP_DECORATE: case OP_MEMBER_DECORATE:   // OpName, OpMemberName and the decorations of live ids
        if (live.count(w[x.at + 1]) && live[w[x.at + 1]]) put(x);
        break;
      default:
        // capabilities, extensions, imports and the memory model; a declaration when it is live
        if (!result_of[k] || x.op == OP_EXT_INST_IMPORT || (live.count(result_of[k]) && live[result_of[k]])) put(x);
    }
  }
  return out;
}

}  // namespace detail
}  // namespace sycl

#endif
