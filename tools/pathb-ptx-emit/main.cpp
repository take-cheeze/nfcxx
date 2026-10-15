// pathb-ptx-emit (C++): phase 1 of the port of scripts/pathb-ptx-emit.rb. Only the reader is ported: --dump-forms prints
// the parsed forms in the canonical text (one per line), for the differential check (diff-forms.sh). Emitting PTX is
// still done by the Ruby script; this binary refuses it (exit status 3) until the lowering phases are ported.
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>

#include "ir.hpp"

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

}  // namespace

int run_eval_cases(const std::string &src);

int main(int argc, char **argv) {
  bool dump = false;
  bool eval = false;
  std::string file = "-";
  bool have_file = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--dump-forms") {
      dump = true;
    } else if (a == "--eval-cases" && i + 1 < argc) {
      eval = true;
      file = argv[++i];
      have_file = true;
    } else if (a.rfind("--sm=", 0) == 0 || a.rfind("--kernel=", 0) == 0) {
      // Accepted for the same command line as the Ruby; not used by the reader.
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
  if (eval) {
    return run_eval_cases(src);
  }
  if (!dump) {
    std::fprintf(stderr, "refused: the C++ emitter is phase 1 (reader only); the Ruby scripts/pathb-ptx-emit.rb emits\n");
    return 3;
  }
  try {
    for (const Node &f : parse_forms_chunked(src)) {
      std::string line = form_text(f);
      line += '\n';
      std::fwrite(line.data(), 1, line.size(), stdout);
    }
  } catch (const BadIR &e) {
    std::string msg = std::string("error: ") + e.what() + "\n";
    std::fwrite(msg.data(), 1, msg.size(), stdout);
    return 1;
  }
  return 0;
}
