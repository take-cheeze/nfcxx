// mrbbc_lower: prints the Path B IR module of an mruby 4.0 RITE file on stdout (tools/mrbbc/mrb_lower.hpp).
//
//   mrbbc_lower [--value=8|4|16] [--export-i64=NAME ...] program.rite > program.ir
//   mrbbc_lower --report-all program.rite
//
// --value is the layout of a register (mrb_lower.hpp, LowerOptions); the runtime is built with the same MRBBC_VALUE.
//
// Exit status: 0 with the IR written; 3 with "refused: ..." on stderr when the program uses something not lowered yet
// (nothing is written to stdout); 1 for a file that does not read (the reader's message on stderr); 2 for usage.
// --report-all writes no IR: it prints every refusal on stdout, one per line (mrb_lower.hpp, report_refusals), and on
// stderr the number of functions scanned and of those with a refusal; it exits 3 when there is any refusal, 0 when the
// program would lower.
#include <cstdio>
#include <fstream>
#include <iterator>
#include <set>
#include <string>
#include <vector>

#include "mrb_lower.hpp"
#include "mrb_rite.hpp"

int main(int argc, char **argv) {
  mrbbc::LowerOptions options;
  const char *path = nullptr;
  bool usage = false, report = false;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--value=8" || arg == "--value=4" || arg == "--value=16") {
      options.value_bytes = std::stoi(arg.substr(8));
    } else if (arg == "--report-all") {
      report = true;
    } else if (arg.compare(0, 13, "--export-i64=") == 0) {
      options.i64_exports.push_back(arg.substr(13));
    } else if (path == nullptr && arg.compare(0, 2, "--") != 0) {
      path = argv[i];
    } else {
      usage = true;
    }
  }
  if (usage || path == nullptr) {
    std::fprintf(stderr, "usage: %s [--value=8|4|16] [--export-i64=NAME ...] [--report-all] program.rite\n", argv[0]);
    return 2;
  }
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    std::fprintf(stderr, "%s: cannot open\n", path);
    return 1;
  }
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  try {
    mrb::Module m = mrb::read_module(bytes.data(), bytes.size());
    if (report) {
      std::size_t functions = 0;
      const std::vector<std::string> lines = mrbbc::report_refusals(m, options, &functions);
      std::set<std::string> refused;
      for (const std::string &line : lines) {
        std::printf("%s\n", line.c_str());
        refused.insert(line.substr(0, line.find_first_of(" :")));
      }
      std::fprintf(stderr, "report: %zu refusals in %zu of %zu functions\n", lines.size(), refused.size(), functions);
      return lines.empty() ? 0 : 3;
    }
    std::string ir = mrbbc::lower_module(m, path, options);
    std::fwrite(ir.data(), 1, ir.size(), stdout);
  } catch (const mrbbc::Refused &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 3;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
  return 0;
}
