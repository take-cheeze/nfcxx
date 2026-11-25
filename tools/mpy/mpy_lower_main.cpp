// mpy_lower FILE.mpy: prints the Path B IR of the module's top-level code on stdout. A refused module prints nothing, reports
// the reason on stderr, and exits 3 (the same status tests/lua54bc/lower/run.sh uses for a refusal).
#include <cstdio>
#include <exception>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "mpy_lower.hpp"

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: mpy_lower FILE.mpy\n");
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "mpy_lower: cannot read %s\n", argv[1]);
    return 2;
  }
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  std::string name = argv[1];
  size_t slash = name.find_last_of('/');
  if (slash != std::string::npos) name = name.substr(slash + 1);
  try {
    mpy::Module m = mpy::load(bytes.data(), bytes.size());
    std::string text = mpy::lower_module_text(m, name);
    std::fwrite(text.data(), 1, text.size(), stdout);
  } catch (const std::exception &e) {
    std::fprintf(stderr, "mpy_lower: %s\n", e.what());
    return 3;
  }
  return 0;
}
