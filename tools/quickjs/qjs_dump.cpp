// qjs_dump: prints the functions of a QuickJS bytecode image, their constants and their instructions (for reading a
// lowering refusal and for the producer's development; the lowering itself is qjs_lower).
//
//   qjs_dump image.qjsbc
#include <cstdio>
#include <exception>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "qjs_bc.hpp"
#include "qjs_insn.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s image.qjsbc\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", argv[1]);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    qjs::Bc bc = qjs::read_bc(bytes);
    for (std::size_t k = 0; k < bc.fns.size(); ++k) {
      const qjs::Fn &f = bc.fns[k];
      std::printf("fn %zu name='%s' args=%d vars=%d defargs=%d stack=%d closures=%zu cpool=%zu code=%zu\n", k, f.name.c_str(),
                  f.arg_count, f.var_count, f.defined_arg_count, f.stack_size, f.closure_vars.size(), f.cpool.size(),
                  f.code.size());
      for (const auto &v : f.vardefs) std::printf("  var '%s' kind=%d const=%d lex=%d\n", v.name.c_str(), v.var_kind, v.is_const, v.is_lexical);
      for (const auto &c : f.closure_vars) std::printf("  closure '%s' idx=%d type=%d\n", c.name.c_str(), c.var_idx, c.closure_type);
      for (std::size_t i = 0; i < f.cpool.size(); ++i) {
        const qjs::Const &c = f.cpool[i];
        std::printf("  const %zu kind=%d i=%d\n", i, static_cast<int>(c.kind), c.i);
      }
      std::size_t pc = 0;
      while (pc < f.code.size()) {
        qjs::Insn in = qjs::decode_insn(f.code, pc);
        std::string extra;
        if (in.target >= 0) extra += " -> " + std::to_string(in.target);
        if (in.atom) {
          std::string nm;
          extra += bc.atom_name(in.atom, nm) ? " atom '" + nm + "'" : " atom ?";
        }
        std::printf("  %4zu %-18s arg=%lld%s\n", pc, in.name.c_str(), static_cast<long long>(in.arg), extra.c_str());
        pc = in.next();
      }
    }
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
