// pathb-ptx-emit --embed: the C++ that goes at the end of a .cu file's host copy (scripts/cuda-embed.rb before). It holds
// the device image of the file's code and the table that maps each kernel's host function to its entry name in that image.
// lib/cuda/nfcxx_cuda.h loads the image when the program starts.
// Usage: pathb-ptx-emit --embed FILE.cubin FILE.ir FILE.kernels [FILE.kernels.addr] > tail.cpp
//        pathb-ptx-emit --embed --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr] > tail.cpp
//   FILE.ir        the device IR (scripts/pathb-dump --ir); its function names are the entry names
//   FILE.kernels   one kernel name per line (cuda-rewrite --device --kernels)
//   DIR            the emitter's groups (--groups-dir): groups.txt has one line per module, "gNNNN.ptx" and the IR names of
//                  its kernels; the module image is DIR/gNNNN.EXT. Each module gets its own image and table.
// A kernel's entry is its IR function: the name itself (extern "C") or the Itanium mangled name _Z<len><name>...
// Overloaded kernels (two IR functions with the same mangled prefix) are refused with exit 3.
#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

[[noreturn]] void refuse(const std::string &msg) {
  std::string text = "refused: " + msg + "\n";
  std::fwrite(text.data(), 1, text.size(), stderr);
  std::exit(3);
}

[[noreturn]] void fail(const std::string &msg) {
  std::string text = "pathb-ptx-emit --embed: " + msg + "\n";
  std::fwrite(text.data(), 1, text.size(), stderr);
  std::exit(1);
}

bool starts_with(const std::string &s, const std::string &p) { return s.compare(0, p.size(), p) == 0; }
bool ends_with(const std::string &s, const std::string &p) {
  return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}

// The non-empty lines of a file.
std::vector<std::string> read_lines(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) fail("cannot read " + path);
  std::vector<std::string> out;
  std::string line;
  while (std::getline(f, line))
    if (!line.empty()) out.push_back(line);
  return out;
}

// The fields of a line split at runs of whitespace (Ruby's split(" ")).
std::vector<std::string> fields(const std::string &line) {
  std::istringstream ss(line);
  std::vector<std::string> out;
  std::string w;
  while (ss >> w) out.push_back(w);
  return out;
}

// An absolute, normalized path (File.expand_path): the .incbin is read when the host copy is assembled, in another directory.
std::string expand_path(const std::string &p) {
  std::string out = std::filesystem::absolute(p).lexically_normal().string();
  if (out.size() > 1 && out.back() == '/') out.pop_back();
  return out;
}

std::string asm_escape(const std::string &t) {
  std::string out;
  for (char c : t) {
    if (c == '\\' || c == '"') out += '\\';
    out += c;
  }
  return out;
}

}  // namespace

int run_embed(int argc, char **argv) {
  std::string groups_dir, ext = "cubin";
  bool grouped = false;
  std::vector<std::string> args;
  for (int i = 0; i < argc; i++) {
    std::string a = argv[i];
    if (starts_with(a, "--groups=")) {
      groups_dir = a.substr(9);
      grouped = true;
    } else if (starts_with(a, "--ext=")) {
      ext = a.substr(6);
    } else {
      args.push_back(a);
    }
  }
  std::string cubin_path, ir_path, kernels_path, addr_path;
  if (!grouped) {
    if (args.size() < 3) {
      std::fprintf(stderr, "usage: pathb-ptx-emit --embed FILE.cubin FILE.ir FILE.kernels [FILE.kernels.addr]\n"
                           "       pathb-ptx-emit --embed --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr]\n");
      return 2;
    }
    cubin_path = args[0], ir_path = args[1], kernels_path = args[2];
    if (args.size() > 3) addr_path = args[3];
  } else {
    if (args.size() < 2) {
      std::fprintf(stderr, "usage: pathb-ptx-emit --embed --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr]\n");
      return 2;
    }
    ir_path = args[0], kernels_path = args[1];
    if (args.size() > 2) addr_path = args[2];
  }

  // IR function names, in order: each line with `(function "NAME"` (the first on the line). The IR is read a line at a time:
  // a large unit's IR is hundreds of MB (llama.cpp's ggml-cuda.cu: 677 MB).
  std::vector<std::string> names;
  {
    std::ifstream f(ir_path, std::ios::binary);
    if (!f) fail("cannot read " + ir_path);
    const std::string head = "(function \"";
    std::string line;
    while (std::getline(f, line)) {
      size_t i = line.find(head);
      if (i == std::string::npos) continue;
      size_t j = line.find('"', i + head.size());
      if (j != std::string::npos) names.push_back(line.substr(i + head.size(), j - (i + head.size())));
    }
  }
  // The names by index: exact_idx has the indices of each name. key_idx: for a name "_Z<digits><ident>" with the digits N and
  // an identifier of N characters, the key is "<digits><ident>", so a kernel K (not starting with a digit) matches the names
  // that start with "_Z<K.length>K" exactly when their key is "<K.length>K". The hits are in IR order.
  std::unordered_map<std::string, std::vector<size_t>> exact_idx, key_idx;
  for (size_t i = 0; i < names.size(); i++) {
    const std::string &n = names[i];
    exact_idx[n].push_back(i);
    if (!starts_with(n, "_Z")) continue;
    size_t e = 2;
    while (e < n.size() && n[e] >= '0' && n[e] <= '9') e++;
    if (e == 2 || e - 2 > 9) continue;  // a length of ten digits or more is longer than any name
    const size_t len = std::stoul(n.substr(2, e - 2));
    if (e + len > n.size()) continue;
    key_idx[n.substr(2, e + len - 2)].push_back(i);
  }
  auto name_hits = [&](const std::string &k) {
    std::vector<std::string> out;
    const std::string prefix = "_Z" + std::to_string(k.size()) + k;
    if (k.empty() || (k[0] >= '0' && k[0] <= '9')) {
      for (const std::string &n : names)
        if (n == k || starts_with(n, prefix)) out.push_back(n);
      return out;
    }
    std::vector<size_t> idx;
    auto add = [&](const std::unordered_map<std::string, std::vector<size_t>> &m, const std::string &key) {
      auto it = m.find(key);
      if (it != m.end()) idx.insert(idx.end(), it->second.begin(), it->second.end());
    };
    add(exact_idx, k);
    add(key_idx, std::to_string(k.size()) + k);
    std::sort(idx.begin(), idx.end());
    idx.erase(std::unique(idx.begin(), idx.end()), idx.end());
    for (size_t i : idx) out.push_back(names[i]);
    return out;
  };

  const std::vector<std::string> kernels = read_lines(kernels_path);
  // Address-taken instances (addr file, from cuda-rewrite): "HOST-EXPRESSION<TAB>WRAPPER" lines. Their wrappers are kernels
  // too (the emitter lowers them), but the host has no name for a wrapper: the table entry is the instance's address.
  std::vector<std::string> addr_lines;
  if (!addr_path.empty() && std::filesystem::exists(addr_path)) addr_lines = read_lines(addr_path);
  std::unordered_set<std::string> addr_wrappers;
  for (const std::string &l : addr_lines) {
    size_t t = l.find('\t');
    if (t != std::string::npos) addr_wrappers.insert(l.substr(t + 1));
  }
  std::vector<std::pair<std::string, std::string>> entries;  // host expression, IR name
  for (const std::string &k : kernels) {
    std::vector<std::string> hits = name_hits(k);
    if (hits.empty()) {
      std::string all;
      for (size_t i = 0; i < names.size(); i++) all += (i ? ", " : "") + names[i];
      refuse("kernel " + k + ": no device function named " + k + " (IR has " + all + ")");
    }
    if (hits.size() > 1) refuse("kernel " + k + ": " + std::to_string(hits.size()) + " device functions match");
    if (!addr_wrappers.count(k)) entries.push_back({k, hits[0]});
  }
  // The table maps the host instance's address (&HOST-EXPRESSION) to the wrapper's entry, so a function pointer the program
  // was handed finds it.
  for (const std::string &line : addr_lines) {
    size_t t = line.find('\t');
    if (t == std::string::npos) refuse("address table line without a wrapper: " + line);
    const std::string host = line.substr(0, t), wrapper = line.substr(t + 1);
    auto it = exact_idx.find(wrapper);
    const size_t n = it == exact_idx.end() ? 0 : it->second.size();
    if (n == 0) refuse("address of " + host + ": no device function named " + wrapper);
    if (n > 1) refuse("address of " + host + ": " + std::to_string(n) + " device functions match");
    entries.push_back({host, wrapper});
  }

  // The modules: the image file, whether it is PTX text (cudaLibraryLoadData reads it as a C string, so the image ends
  // with a NUL), and its entries. The single-image form is one module with all the entries.
  struct Module {
    std::string path;
    bool nul;
    std::vector<std::pair<std::string, std::string>> table;
  };
  std::vector<Module> modules;
  if (!grouped) {
    modules.push_back({expand_path(cubin_path), ends_with(cubin_path, ".ptx"), entries});
  } else {
    std::map<std::string, size_t> group_of;
    std::vector<std::string> files;
    for (const std::string &line : read_lines(groups_dir + "/groups.txt")) {
      std::vector<std::string> parts = fields(line);
      if (parts.empty()) continue;
      for (size_t p = 1; p < parts.size(); p++) group_of[parts[p]] = files.size();
      files.push_back(parts[0]);
    }
    std::vector<std::vector<std::pair<std::string, std::string>>> by_group(files.size());
    for (const auto &[host, ir] : entries) {
      auto it = group_of.find(ir);
      if (it == group_of.end()) refuse("kernel " + host + ": device function " + ir + " is in no module of " + groups_dir);
      by_group[it->second].push_back({host, ir});
    }
    for (size_t gi = 0; gi < files.size(); gi++) {
      const std::string &f = files[gi];
      const std::string base = f.substr(0, f.size() >= 4 ? f.size() - 4 : 0);  // gNNNN.ptx -> gNNNN
      modules.push_back({expand_path(groups_dir + "/" + base + "." + ext), ext == "ptx", by_group[gi]});
    }
  }

  // The image is not C text: a byte array of ~6 characters a byte made the host copy of a large file (llama.cpp's mmvf.cu:
  // 494 MB) too big for the front end. The image is an assembler .incbin of the module's file, in the same object: a
  // top-level asm block, which the back ends pass through, so the symbol is in the object the compile writes. The symbol is
  // local to the object (two objects can each have __nfcxx_image_0). The C side declares it and gives its size, which is
  // known here. The .incbin path is read at assembly time: the file must exist during the compile.
  std::string out = "// Generated by pathb-ptx-emit --embed: the device image of this file and its kernel table. Do not edit.\n";
  for (size_t mi = 0; mi < modules.size(); mi++) {
    const Module &m = modules[mi];
    // the single image keeps the names it always had; with several modules each one is numbered
    const std::string sfx = grouped ? "_" + std::to_string(mi) : "";
    std::error_code ec;
    const uintmax_t file_size = std::filesystem::file_size(m.path, ec);
    if (ec) fail("cannot read " + m.path);
    const std::string size = std::to_string(file_size + (m.nul ? 1 : 0));
    const std::string sym = "__nfcxx_image" + sfx;
    std::vector<std::string> asm_lines = {".pushsection .rodata", ".balign 16", ".local " + sym, ".type " + sym + ", @object",
                                          sym + ":", ".incbin \"" + asm_escape(m.path) + "\""};
    if (m.nul) asm_lines.push_back(".byte 0");
    asm_lines.push_back(".size " + sym + ", " + size);
    asm_lines.push_back(".popsection");
    out += "__asm__(\n";
    for (const std::string &l : asm_lines) out += "  \"" + asm_escape(l) + "\\n\"\n";
    out += ");\n";
    out += "extern const unsigned char " + sym + "[];\n";
    out += "static const __nfcxx_kernel_entry __nfcxx_kernels" + sfx + "[] = {\n";
    for (const auto &[k, e] : m.table) out += "  {(const void *)&" + k + ", \"" + e + "\"},\n";
    if (m.table.empty()) out += "  {(const void *)0, (const char *)0},\n";
    out += "};\n";
    out += "static const __nfcxx_module_init __nfcxx_module" + sfx + "(" + sym + ", " + size + ", __nfcxx_kernels" + sfx + ", " +
           std::to_string(m.table.size()) + ");\n";
  }
  std::fwrite(out.data(), 1, out.size(), stdout);
  return std::fflush(stdout) == 0 ? 0 : 1;
}
