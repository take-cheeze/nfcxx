// pathb-ptx-emit (C++): the port of scripts/pathb-ptx-emit.rb, phase by phase. Ported: the reader (--dump-forms prints
// the parsed forms in the canonical text, for diff-forms.sh), the type and constant helpers, the arithmetic, and the
// module level (--plan prints the module without its function bodies, for diff-plan.sh: the classification, the kernel
// selection, the functions kept and their order, the recursion check, the declarations). Not ported: the function bodies
// (Fn#compile), so emitting PTX is refused (exit status 3) after the module checks, and the Ruby script emits.
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#include "ir.hpp"
#include "lower_types.hpp"
#include "module.hpp"
#include "module_decls.hpp"

namespace {

bool read_all(const std::string &path, std::string &out) {
  if (path == "-") {
    std::ostringstream ss;
    ss << std::cin.rdbuf();
    out = ss.str();
    return true;
  }
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
  return true;
}

// Writes a diagnostic with its whole text: a message may hold a NUL byte (a name from the IR), which %s would cut.
void write_err(const char *prefix, const std::string &msg) {
  std::string text = std::string(prefix) + msg + "\n";
  std::fwrite(text.data(), 1, text.size(), stderr);
}

}  // namespace

int run_eval_cases(const std::string &src);
int run_eval_arith(const std::string &src);

int main(int argc, char **argv) {
  bool dump = false;
  bool decls = false;
  bool eval = false;
  bool arith = false;
  bool plan = false;
  std::string sm = "sm_75";
  std::vector<std::string> kernels;
  std::string file = "-";
  bool have_file = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--dump-forms") {
      dump = true;
    } else if (a == "--plan") {
      plan = true;
    } else if (a == "--decls") {
      decls = true;
    } else if (a.rfind("--sm=", 0) == 0) {
      sm = "sm_" + a.substr(5);
    } else if (a.rfind("--kernel=", 0) == 0) {
      kernels.push_back(a.substr(9));
    } else if (a == "--eval-cases" && i + 1 < argc) {
      eval = true;
      file = argv[++i];
      have_file = true;
    } else if (a == "--eval-arith" && i + 1 < argc) {
      arith = true;
      file = argv[++i];
      have_file = true;
    } else if (a.size() > 1 && a[0] == '-' && a[1] == '-') {
      std::fprintf(stderr, "usage: pathb-ptx-emit [--sm=75] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n");
      return 1;
    } else if (!have_file) {
      file = a;
      have_file = true;
    } else {
      std::fprintf(stderr, "usage: pathb-ptx-emit [--sm=75] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n");
      return 1;
    }
  }
  std::string src;
  if (!read_all(file, src)) {
    std::fprintf(stderr, "error: cannot read %s\n", file.c_str());
    return 1;
  }
  if (arith) {
    return run_eval_arith(src);
  }
  if (eval) {
    return run_eval_cases(src);
  }
  if (plan) {
    try {
      std::string text = plan_module(src, sm, kernels);
      std::fwrite(text.data(), 1, text.size(), stdout);
    } catch (const Refused &e) {
      write_err("refused: ", e.text);
      return 3;
    } catch (const BadIR &e) {
      write_err("error: ", e.text);
      return 1;
    }
    return 0;
  }
  if (decls) {
    try {
      std::string out = emit_module_decls(src, false, false);
      std::fwrite(out.data(), 1, out.size(), stdout);
    } catch (const Refused &e) {
      write_err("refused: ", e.text);
      return 3;
    } catch (const BadIR &e) {
      write_err("error: ", e.text);
      return 1;
    }
    return 0;
  }
  if (!dump) {
    // The module checks above pass, so the Ruby would now lower the function bodies (Fn#compile), which this emitter
    // does not do yet. The refusal keeps the status of a module the emitter cannot emit.
    try {
      plan_module(src, sm, kernels);
    } catch (const Refused &e) {
      write_err("refused: ", e.text);
      return 3;
    } catch (const BadIR &e) {
      write_err("error: ", e.text);
      return 1;
    }
    std::fprintf(stderr, "refused: the C++ emitter does not lower function bodies yet (Fn#compile); the Ruby scripts/pathb-ptx-emit.rb emits\n");
    return 3;
  }
  try {
    // With kernels, only the functions they reach are parsed (parse_module_forms); the fn-indices line gives the
    // position of each parsed function among the module's functions, or "all" where the whole text is parsed.
    std::vector<Node> forms;
    std::string indices;
    ModuleForms mf;
    if (!kernels.empty() && parse_module_forms(src, kernels, mf)) {
      forms = std::move(mf.forms);
      indices = "# fn-indices:";
      for (size_t idx : mf.fn_indices) indices += " " + std::to_string(idx);
    } else {
      forms = parse_forms_chunked(src);
      if (!kernels.empty()) indices = "# fn-indices: all";
    }
    for (const Node &f : forms) {
      std::string line = form_text(f);
      line += '\n';
      std::fwrite(line.data(), 1, line.size(), stdout);
    }
    if (!indices.empty()) {
      indices += '\n';
      std::fwrite(indices.data(), 1, indices.size(), stdout);
    }
  } catch (const BadIR &e) {
    std::string msg = std::string("error: ") + e.text + "\n";
    std::fwrite(msg.data(), 1, msg.size(), stdout);
    return 1;
  }
  return 0;
}
