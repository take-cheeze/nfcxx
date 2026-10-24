// The device images of a process for the OpenCL and Level Zero runtimes (rt_opencl.hpp, rt_level_zero.hpp). Each TU built by
// scripts/sycl-build.sh has its own image: PREFIX.cl.spv (the SPIR-V of its kernels) and PREFIX.man (the manifest of
// scripts/pathb-spirv-emit.rb: the kernels by closure type, the stack size, the sub-group size, the statics and their
// relocations). The TU registers its prefix (NFCXX_SYCL_IMAGE_PREFIX, baked in by the build) from a static initializer at
// the end of sycl.hpp, so a program linked from several TUs, or a shared library of them, carries every image.
//
// The runtime loads the registered images it has not loaded yet when it starts and whenever a closure type is not found,
// so an image registered after the runtime started (a library opened later) is found too. A closure type in two images (a
// kernel of a template or an inline function, instantiated in two TUs) resolves to the first image loaded; each image keeps
// its own statics, so such a kernel sees the statics of the image it came from.
//
// Environment: NFCXX_SYCL_IMAGE, a colon-separated list of prefixes loaded in place of the registered ones.
#ifndef NFCXX_SYCL_RT_IMAGE_HPP
#define NFCXX_SYCL_RT_IMAGE_HPP

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace sycl {
namespace detail {

// The prefixes the TUs registered, in registration order.
inline std::vector<std::string> &image_registry() {
  static std::vector<std::string> v;
  return v;
}
inline int register_image(const char *prefix) {
  image_registry().push_back(prefix);
  return 0;
}

// One image: its SPIR-V and the module-wide facts of its manifest. statics is the device address of its statics once loaded.
struct image_module {
  std::string prefix;
  std::vector<uint8_t> il;
  uint32_t stack_bytes = 0;
  uint32_t subgroup_size = 0;    // the sub-group size of the module's kernels (manifest line G), 0 when none uses sub-groups
  uint64_t static_size = 0, statics = 0;
  uint64_t static_local = 0;     // the work-group static bytes per group (manifest L)
  std::string static_hex;
  std::vector<std::pair<uint64_t, uint64_t>> relocs;
};

struct image_kernel {
  std::string entry;
  uint32_t closure_size;
  size_t module;                 // the index of its image in image_set::modules
};

class image_set {
 public:
  std::vector<image_module> modules;

  const image_kernel *find(const std::string &key) const {
    auto it = kernels_.find(key);
    return it == kernels_.end() ? nullptr : &it->second;
  }
  size_t kernel_count() const { return kernels_.size(); }

  // Loads the images not loaded yet. alloc(bytes) gives a device address, write(addr, src, n) fills it, fail(why) does not
  // return. Returns true when an image was added.
  template <class Alloc, class Write, class Fail>
  bool load_pending(Alloc alloc, Write write, Fail fail) {
    std::vector<std::string> want;
    if (const char *env = std::getenv("NFCXX_SYCL_IMAGE")) {
      std::string s(env);
      for (size_t a = 0; a <= s.size();) {
        size_t b = s.find(':', a);
        if (b == std::string::npos) b = s.size();
        if (b > a) want.push_back(s.substr(a, b - a));
        a = b + 1;
      }
    } else {
      want = image_registry();
    }
    if (want.empty()) fail("no device image: the program was not built by scripts/sycl-build.sh (or set NFCXX_SYCL_IMAGE)");
    bool added = false;
    for (; seen_ < want.size(); seen_++) {
      const std::string &prefix = want[seen_];
      bool dup = false;
      for (const auto &m : modules) dup = dup || m.prefix == prefix;
      if (dup) continue;
      load(prefix, alloc, write, fail);
      added = true;
    }
    return added;
  }

 private:
  std::map<std::string, image_kernel> kernels_;
  size_t seen_ = 0;   // the entries of the wanted list already handled

  template <class Alloc, class Write, class Fail>
  void load(const std::string &prefix, Alloc alloc, Write write, Fail fail) {
    image_module m;
    m.prefix = prefix;
    std::vector<std::pair<std::string, image_kernel>> ks;
    std::string path = prefix + ".man";
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) fail("cannot read " + path);
    char line[4096];
    size_t index = modules.size();
    while (std::fgets(line, sizeof line, f)) {
      std::string s(line);
      while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
      if (s.size() >= 2 && s[0] == 'k' && s.find('\t') != std::string::npos) {
        size_t a = s.find('\t'), b = s.find('\t', a + 1);
        ks.push_back({s.substr(a + 1, b - a - 1), image_kernel{s.substr(0, a), (uint32_t)std::strtoul(s.c_str() + b + 1, nullptr, 10), index}});
      } else if (s.size() > 2 && s[0] == 'T' && s[1] == '\t') {
        m.stack_bytes = (uint32_t)std::strtoul(s.c_str() + 2, nullptr, 10);
      } else if (s.size() > 2 && s[0] == 'G' && s[1] == '\t') {
        m.subgroup_size = (uint32_t)std::strtoul(s.c_str() + 2, nullptr, 10);
      } else if (s.size() > 2 && s[0] == 'S' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        m.static_size = std::strtoull(s.c_str() + 2, nullptr, 10);
        m.static_hex = s.substr(a + 1);
      } else if (s.size() > 2 && s[0] == 'L' && s[1] == '\t') {
        m.static_local = std::strtoull(s.c_str() + 2, nullptr, 10);
      } else if (s.size() > 2 && s[0] == 'R' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        m.relocs.push_back({std::strtoull(s.c_str() + 2, nullptr, 10), std::strtoull(s.c_str() + a + 1, nullptr, 10)});
      }
    }
    std::fclose(f);
    // a TU without kernels has an empty module: nothing to read or place
    if (!ks.empty()) {
      std::string il_path = prefix + ".cl.spv";
      FILE *g = std::fopen(il_path.c_str(), "rb");
      if (!g) fail("cannot read " + il_path);
      std::fseek(g, 0, SEEK_END);
      size_t n = (size_t)std::ftell(g);
      std::rewind(g);
      m.il.resize(n);
      if (std::fread(m.il.data(), 1, n, g) != n) fail("short read of " + il_path);
      std::fclose(g);
      // the statics: the constant tables and globals, relocated to device addresses
      if (m.static_size) {
        m.statics = alloc(m.static_size);
        std::vector<uint8_t> img(m.static_size, 0);
        for (size_t i = 0; i + 1 < m.static_hex.size() && i / 2 < img.size(); i += 2)
          img[i / 2] = (uint8_t)std::strtoul(m.static_hex.substr(i, 2).c_str(), nullptr, 16);
        for (auto &r : m.relocs) {
          uint64_t v = m.statics + r.second;
          std::memcpy(&img[r.first], &v, 8);
        }
        write(m.statics, img.data(), img.size());
      }
      m.static_hex.clear();
    }
    modules.push_back(std::move(m));
    for (auto &k : ks) kernels_.insert(k);   // the first image of a closure type keeps it
  }
};

}  // namespace detail
}  // namespace sycl

#endif
