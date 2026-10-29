// pathb-ptx-emit (C++): the port of scripts/pathb-ptx-emit.rb, phase by phase. --emit writes the module's PTX
// (emit_module.cpp), the same text as the Ruby script (NFCXX_PTX_EMITTER=cxx selects this one in the driver). --dump-forms
// prints the parsed forms in the canonical text (diff-forms.sh); --plan prints the module without its function bodies
// (diff-plan.sh); --decls prints the declarations (diff-module-decls.sh); --embed writes the registration tail of a .cu
// file's host copy (embed.cpp).
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

#include "emit_module.hpp"
#include "ir.hpp"
#include "lower_arith.hpp"
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
  // the file is read into one buffer of its size (a byte-iterator copy grows the string and copies it again)
  f.seekg(0, std::ios::end);
  const std::streamoff size = f.tellg();
  f.seekg(0, std::ios::beg);
  if (size < 0) {
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
  }
  out.resize(static_cast<size_t>(size));
  f.read(&out[0], size);
  out.resize(static_cast<size_t>(f.gcount()));
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
int run_embed(int argc, char **argv);

int main(int argc, char **argv) {
  // --embed (embed.cpp): the registration tail of a .cu file's host copy, from the emitter's groups; its own arguments.
  if (argc > 1 && std::string(argv[1]) == "--embed") return run_embed(argc - 2, argv + 2);
  bool dump = false;
  bool decls = false;
  bool eval = false;
  bool arith = false;
  bool plan = false;
  bool emit = false;
  std::string sm = "sm_75";
  std::string groups_dir;  // --groups-dir=DIR: the grouped emit (g0000.ptx, ... and groups.txt in DIR)
  size_t max_const_bytes = 65536, max_ptx_lines = 60000;
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
    } else if (a == "--f2i=convert") {
      g_f2i_convert = true;
    } else if (a == "--int=gpu") {
      g_int_gpu = true;
    } else if (a == "--inline=device") {
      g_inline_device = true;
    } else if (a == "--promote=slots") {
      g_promote_slots = true;
    } else if (a == "--promote=off") {
      g_promote_slots = false;
    } else if (a == "--unroll=loops") {
      g_unroll_loops = true;
    } else if (a == "--unroll=off") {
      g_unroll_loops = false;
    } else if (a.rfind("--sm=", 0) == 0) {
      sm = "sm_" + a.substr(5);
    } else if (a.rfind("--kernel=", 0) == 0) {
      kernels.push_back(a.substr(9));
    } else if (a.rfind("--groups-dir=", 0) == 0) {
      groups_dir = a.substr(13);
    } else if (a.rfind("--max-const-bytes=", 0) == 0) {
      max_const_bytes = std::stoull(a.substr(18));
    } else if (a.rfind("--max-ptx-lines=", 0) == 0) {
      max_ptx_lines = std::stoull(a.substr(16));
    } else if (a == "--eval-cases" && i + 1 < argc) {
      eval = true;
      file = argv[++i];
      have_file = true;
    } else if (a == "--eval-arith" && i + 1 < argc) {
      arith = true;
      file = argv[++i];
      have_file = true;
    } else if (a == "--emit") {
      emit = true;
    } else if (a.size() > 1 && a[0] == '-' && a[1] == '-') {
      std::fprintf(stderr, "usage: pathb-ptx-emit [--sm=75] [--f2i=convert] [--int=gpu] [--inline=device] [--promote=slots|off] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n");
      return 1;
    } else if (!have_file) {
      file = a;
      have_file = true;
    } else {
      std::fprintf(stderr, "usage: pathb-ptx-emit [--sm=75] [--f2i=convert] [--int=gpu] [--inline=device] [--promote=slots|off] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n");
      return 1;
    }
  }
  if (emit && !arith && !eval && !plan && !decls) {
    // The module is read chunk by chunk from the file (a standard input is read whole first). Exit 3 on a refusal, 1 on
    // malformed IR; nothing is written to stdout then.
    std::string whole;
    ModuleText text(nullptr, file);
    if (file == "-") {
      if (!read_all(file, whole)) {
        std::fprintf(stderr, "error: cannot read %s\n", file.c_str());
        return 1;
      }
      text = ModuleText(&whole, "");
    } else if (!std::ifstream(file, std::ios::binary)) {
      std::fprintf(stderr, "error: cannot read %s\n", file.c_str());
      return 1;
    }
    if (!groups_dir.empty()) {
      // The grouped emit: one module per group of kernels (see emit_module_groups), written to the directory with the
      // group index (kernel names are the IR names). A refusal writes no group.
      std::string index;
      try {
        std::error_code ec;
        std::filesystem::create_directories(groups_dir, ec);
        if (ec) {
          std::fprintf(stderr, "error: cannot create %s\n", groups_dir.c_str());
          return 1;
        }
        emit_module_groups(text, sm, kernels, GroupBudget{max_const_bytes, max_ptx_lines},
                           [&](size_t i, const std::vector<std::string> &names, const std::string &ptx) {
                             char base[32];
                             std::snprintf(base, sizeof base, "g%04zu.ptx", i);
                             std::string path = groups_dir + "/" + base;
                             FILE *f = std::fopen(path.c_str(), "wb");
                             if (!f || std::fwrite(ptx.data(), 1, ptx.size(), f) != ptx.size() || std::fclose(f) != 0) {
                               std::fprintf(stderr, "error: cannot write %s\n", path.c_str());
                               std::exit(1);
                             }
                             index += base;
                             for (const std::string &k : names) index += " " + k;
                             index += "\n";
                           });
      } catch (const Refused &e) {
        std::fprintf(stderr, "refused: %s\n", e.what());
        return 3;
      } catch (const BadIR &e) {
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
      }
      std::string path = groups_dir + "/groups.txt";
      FILE *f = std::fopen(path.c_str(), "wb");
      if (!f || std::fwrite(index.data(), 1, index.size(), f) != index.size() || std::fclose(f) != 0) {
        std::fprintf(stderr, "error: cannot write %s\n", path.c_str());
        return 1;
      }
      return 0;
    }
    auto sink = [](const std::string &piece) { std::fwrite(piece.data(), 1, piece.size(), stdout); };
    try {
      emit_module(text, sm, kernels, sink);
    } catch (const Refused &e) {
      std::fprintf(stderr, "refused: %s\n", e.what());
      return 3;
    } catch (const BadIR &e) {
      std::fprintf(stderr, "error: %s\n", e.what());
      return 1;
    }
    return 0;
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
