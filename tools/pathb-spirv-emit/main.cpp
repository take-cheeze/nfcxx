// build/pathb-spirv-emit: the C++ port of scripts/pathb-spirv-emit.rb, the same command line and the same output.
//   pathb-spirv-emit [--kernel-cl] [--manifest=FILE] [FILE.ir | -] > out.spv
// Exit status: 0 the module was written (binary, to stdout); 3 refused (reason on stderr); 1 malformed IR.
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <string>

#include "emit.hpp"
#include "ir.hpp"

int main(int argc, char **argv) {
  std::string manifest_path;
  bool have_manifest = false, kernel_cl = false;
  int i = 1;
  for (; i < argc && std::strncmp(argv[i], "--", 2) == 0; i++) {
    std::string opt = argv[i];
    if (opt.compare(0, 11, "--manifest=") == 0) {
      manifest_path = opt.substr(11);
      have_manifest = true;
    } else if (opt == "--kernel-cl") {
      kernel_cl = true;
    } else {
      std::fputs("usage: pathb-spirv-emit.rb [--kernel-cl] [--manifest=FILE] [FILE.ir | -] > out.spv\n", stderr);
      return 1;
    }
  }
  std::string src;
  if (i >= argc || std::strcmp(argv[i], "-") == 0) {
    std::ostringstream ss;
    ss << std::cin.rdbuf();
    src = ss.str();
  } else {
    std::ifstream f(argv[i], std::ios::binary);
    if (!f) {
      std::fprintf(stderr, "pathb-spirv-emit: cannot read %s\n", argv[i]);
      return 1;
    }
    src.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
  }
  Emitted out;
  try {
    out = emit_module(src, kernel_cl);
  } catch (Refused &e) {
    std::string m = "refused: " + e.text + "\n";
    std::fwrite(m.data(), 1, m.size(), stderr);
    return 3;
  } catch (BadIR &e) {
    std::string m = "error: " + e.text + "\n";
    std::fwrite(m.data(), 1, m.size(), stderr);
    return 1;
  } catch (std::exception &e) {
    std::fprintf(stderr, "pathb-spirv-emit: %s\n", e.what());
    return 1;
  }
  if (out.has_module) {
    std::fwrite(out.words.data(), 4, out.words.size(), stdout);   // little-endian words (x86, aarch64)
    std::fflush(stdout);
  }
  if (have_manifest) {
    std::ofstream m(manifest_path, std::ios::binary);
    std::string text;
    for (size_t k = 0; k < out.manifest.size(); k++) {
      if (k) text += '\n';
      text += out.manifest[k];
    }
    text += '\n';
    m << text;
  }
  return 0;
}
