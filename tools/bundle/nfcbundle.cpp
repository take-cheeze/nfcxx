// nfcbundle: copy the shared libraries an x86-64 ELF executable or shared object needs into it, so the result loads
// without them (the idea of pfnet/sold, written anew; sold handles shared objects only, this also takes executables).
//
//   nfcbundle [-v] [--list] [-L DIR]... [--exclude NAME]... [--only NAME]... [--add NAME]... [--export=all|main]
//             [--runpath LIST | --rpath LIST] [--stubs DIR] IN -o OUT
//
// The libraries reachable through DT_NEEDED are found as ld.so finds them (DT_RPATH, LD_LIBRARY_PATH, DT_RUNPATH, -L,
// /etc/ld.so.conf, the default directories). Each one that is not excluded is copied, segment by segment, above the
// input's own address range ("units": the input first, then the libraries in load order). The glibc libraries (libc,
// libm, libpthread, libdl, librt, ld.so, ...) and the GPU driver's (libcuda, libnvidia-*) are always left out: they stay
// DT_NEEDED of the output. A library that an excluded library needs is left out too, so a process never holds two
// copies of it. --stubs writes an empty stand-in for each bundled library, for plugins that name one in DT_NEEDED.
//
// What the output carries, in one new read-write PT_LOAD after the units (docs/notes/bundle.md):
//   - one TLS block: the units' blocks side by side, the input's last so its local-exec offsets from %fs stay right;
//     the module-relative offsets of the other units are rewritten (DTPOFF64 values, the offset word of each
//     local-dynamic GOT pair, TPOFF64 addends);
//   - one .eh_frame_hdr whose search table covers every unit's FDEs (the unwinder looks at a single PT_GNU_EH_FRAME
//     per object; when the units span more than 2 GiB it has a PT_LOAD of its own in their middle);
//   - one DT_INIT_ARRAY / DT_FINI_ARRAY: each unit's DT_INIT and init array, dependencies first, the input last (and
//     the reverse for the fini side);
//   - a new dynamic section, symbol table (DT_HASH), versions and one RELA table. A reference whose definition is in a
//     unit is bound when bundling (RELATIVE, IRELATIVE, or a constant), except that a shared object output keeps a
//     reference to one of its exported definitions symbolic, so the program loading it can still interpose it or take
//     it by a copy relocation; a reference into an excluded library stays a symbolic relocation with its version. The
//     PLT slots are filled at load time (DF_BIND_NOW): there is one GOT per unit but only one DT_PLTGOT, so lazy
//     binding cannot work. A copy relocation of the input whose source is bundled is done when bundling.
// The output's dynamic symbols are the input's and (--export=all, the default) the default-visibility definitions of
// the bundled libraries, unversioned, so an excluded library (libc) still binds to an interposing definition such as a
// bundled malloc. The input's section headers are replaced by new ones (one section per unit segment and the new
// tables), which is what ld needs to link against an output shared object; the static symbol tables are not kept.
#include <elf.h>
#include <glob.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

[[noreturn]] void die(const std::string &m) {
  fprintf(stderr, "nfcbundle: %s\n", m.c_str());
  exit(1);
}
bool verbose = false;
void note(const std::string &m) {
  if (verbose) fprintf(stderr, "nfcbundle: %s\n", m.c_str());
}
std::string hex(uint64_t v) {
  char b[32];
  snprintf(b, sizeof b, "0x%llx", (unsigned long long)v);
  return b;
}
uint64_t align_up(uint64_t v, uint64_t a) { return a <= 1 ? v : (v + a - 1) / a * a; }
const uint64_t PAGE = 0x1000;

std::string basename_of(const std::string &p) {
  size_t s = p.rfind('/');
  return s == std::string::npos ? p : p.substr(s + 1);
}
std::string dirname_of(const std::string &p) {
  size_t s = p.rfind('/');
  return s == std::string::npos ? "." : s == 0 ? "/" : p.substr(0, s);
}
std::vector<std::string> split(const std::string &s, char c) {
  std::vector<std::string> r;
  size_t b = 0;
  for (;;) {
    size_t e = s.find(c, b);
    std::string t = s.substr(b, e == std::string::npos ? std::string::npos : e - b);
    if (!t.empty()) r.push_back(t);
    if (e == std::string::npos) return r;
    b = e + 1;
  }
}
// A file's contents, mapped read-only (the inputs can be gigabytes: libtorch_cuda.so is 1.6 GB).
struct Bytes {
  const uint8_t *p = nullptr;
  size_t n = 0;
  const uint8_t *data() const { return p; }
  size_t size() const { return n; }
};
bool read_file(const std::string &path, Bytes &d) {
  int fd = open(path.c_str(), O_RDONLY);
  if (fd < 0) return false;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
    close(fd);
    errno = EINVAL;
    return false;
  }
  d.n = st.st_size;
  void *m = d.n ? mmap(nullptr, d.n, PROT_READ, MAP_PRIVATE, fd, 0) : nullptr;
  close(fd);
  if (m == MAP_FAILED) return false;
  d.p = (const uint8_t *)m;
  return true;
}

// The glibc libraries: they rely on ld.so's internals (and on being the one copy in the process), so they are never
// bundled. Matched on the soname up to ".so".
bool is_glibc(const std::string &soname) {
  static const char *const names[] = {"libc", "libm", "libpthread", "libdl", "librt", "libutil", "libresolv",
                                      "libanl", "libnsl", "libBrokenLocale", "libmvec", "libthread_db", "libcrypt",
                                      "libc_malloc_debug", "libmemusage", "libpcprofile", "libSegFault"};
  std::string stem = soname.substr(0, soname.find(".so"));
  if (stem.rfind("ld-linux", 0) == 0 || stem.rfind("ld64", 0) == 0 || stem == "ld" || stem.rfind("libnss_", 0) == 0)
    return true;
  for (const char *n : names)
    if (stem == n) return true;
  return false;
}

// The libraries of a GPU driver (and the GL/Vulkan/OpenCL dispatchers that load them): they have to match the kernel
// driver of the machine the program runs on, so they are never bundled either. libcuda.so.1 is usually not a
// DT_NEEDED at all (the CUDA runtime dlopens it); when it is, it may also be missing on the build machine.
bool is_driver(const std::string &soname) {
  static const char *const names[] = {"libcuda", "libnvcuvid", "libnvoptix", "libGL", "libGLX", "libEGL", "libGLdispatch",
                                      "libGLESv1_CM", "libGLESv2", "libOpenGL", "libvulkan", "libOpenCL"};
  std::string stem = soname.substr(0, soname.find(".so"));
  if (stem.rfind("libnvidia-", 0) == 0 || stem.rfind("libGLX_", 0) == 0 || stem.rfind("libEGL_", 0) == 0) return true;
  for (const char *n : names)
    if (stem == n) return true;
  return false;
}
bool is_system(const std::string &soname) { return is_glibc(soname) || is_driver(soname); }

struct Obj {
  std::string path, soname;
  std::string needed_as;  // the DT_NEEDED name it was first loaded by (libcublas-4cc45526.so.12 for libcublas.so.12)
  Bytes d;
  Elf64_Ehdr eh{};
  std::vector<Elf64_Phdr> ph;
  bool bundled = false, is_main = false, excluded = false;
  std::vector<std::string> needed;
  std::vector<Obj *> deps;
  std::string rpath, runpath;
  bool has_rpath = false, has_runpath = false;
  const Elf64_Sym *syms = nullptr;
  size_t nsyms = 0;
  uint64_t strtab_va = 0, strsz = 0;
  const char *strtab = nullptr;
  const uint16_t *versym = nullptr;
  std::map<int, std::string> verdef;  // index -> version name
  struct Need {
    std::string file, name;
    uint16_t flags;
  };
  std::map<int, Need> verneed;  // vna_other -> file and version
  uint64_t verdef_va = 0, verdefnum = 0;
  std::vector<Elf64_Rela> rel;
  std::unordered_map<uint64_t, size_t> rel_at;  // r_offset -> index in rel
  uint64_t init = 0, fini = 0, init_array = 0, init_arraysz = 0, fini_array = 0, fini_arraysz = 0;
  uint64_t flags = 0, flags_1 = 0;
  bool symbolic = false, textrel = false, has_debug = false;
  const Elf64_Phdr *tls = nullptr, *ehframe = nullptr, *dynamic = nullptr, *stack = nullptr;
  uint64_t base = 0, tls_off = 0;
  uint64_t lo = 0, hi = 0;  // lowest and highest PT_LOAD address (unrelocated)

  const uint8_t *at(uint64_t va, size_t n) const {
    for (const Elf64_Phdr &p : ph)
      if (p.p_type == PT_LOAD && va >= p.p_vaddr && va + n <= p.p_vaddr + p.p_filesz && p.p_offset + p.p_filesz <= d.size())
        return d.data() + p.p_offset + (va - p.p_vaddr);
    return nullptr;
  }
  // A word of the unit's memory image before relocation: file contents, or zero in a bss part.
  uint64_t rd64(uint64_t va) const {
    const uint8_t *p = at(va, 8);
    uint64_t v = 0;
    if (p) memcpy(&v, p, 8);
    return v;
  }
  const char *str(uint64_t off) const {
    if (!strtab || off >= strsz) die(path + ": string offset " + hex(off) + " outside DT_STRTAB");
    return strtab + off;
  }
  std::string symname(size_t i) const { return str(syms[i].st_name); }
  bool defined(size_t i) const { return syms[i].st_shndx != SHN_UNDEF; }
  bool has_soname = false;
  // An executable, not a shared object that also runs (libc.so.6 has a PT_INTERP and a DT_SONAME).
  bool exe() const {
    if (eh.e_type == ET_EXEC || (flags_1 & DF_1_PIE)) return true;
    for (const Elf64_Phdr &p : ph)
      if (p.p_type == PT_INTERP) return !has_soname;
    return false;
  }
};

std::vector<std::unique_ptr<Obj>> objs;  // everything loaded, in breadth-first load order (the input first)
std::vector<std::string> opt_libdirs, opt_exclude, opt_only, opt_add;
std::string opt_runpath, opt_stubs;  // --runpath / --rpath LIST (replaces the computed search path), --stubs DIR
bool runpath_set = false, rpath_kind = false;  // rpath_kind: --rpath (DT_RPATH, which also covers the plugins' loads)
bool export_all = true;

Obj *load(const std::string &path, bool must) {
  auto o = std::make_unique<Obj>();
  o->path = path;
  if (!read_file(path, o->d)) {
    if (must) die("cannot read " + path + ": " + strerror(errno));
    return nullptr;
  }
  const Bytes &d = o->d;
  if (d.size() < sizeof(Elf64_Ehdr) || memcmp(d.data(), ELFMAG, SELFMAG) != 0) {
    if (must) die(path + ": not an ELF file");
    return nullptr;
  }
  memcpy(&o->eh, d.data(), sizeof o->eh);
  if (o->eh.e_ident[EI_CLASS] != ELFCLASS64 || o->eh.e_ident[EI_DATA] != ELFDATA2LSB || o->eh.e_machine != EM_X86_64) {
    if (must) die(path + ": only x86-64 ELF64 objects are supported");
    return nullptr;
  }
  if (o->eh.e_type != ET_DYN && o->eh.e_type != ET_EXEC) {
    if (must) die(path + ": not an executable or shared object");
    return nullptr;
  }
  if (o->eh.e_phentsize != sizeof(Elf64_Phdr) || o->eh.e_phoff + (uint64_t)o->eh.e_phnum * sizeof(Elf64_Phdr) > d.size())
    die(path + ": bad program headers");
  o->ph.resize(o->eh.e_phnum);
  memcpy(o->ph.data(), d.data() + o->eh.e_phoff, o->eh.e_phnum * sizeof(Elf64_Phdr));
  bool first = true;
  for (const Elf64_Phdr &p : o->ph) {
    if (p.p_type == PT_LOAD) {
      if (p.p_offset + p.p_filesz > d.size()) die(path + ": PT_LOAD outside the file");
      if (first || p.p_vaddr < o->lo) o->lo = p.p_vaddr;
      if (first || p.p_vaddr + p.p_memsz > o->hi) o->hi = p.p_vaddr + p.p_memsz;
      first = false;
    }
    if (p.p_type == PT_TLS) o->tls = &p;
    if (p.p_type == PT_GNU_EH_FRAME) o->ehframe = &p;
    if (p.p_type == PT_DYNAMIC) o->dynamic = &p;
    if (p.p_type == PT_GNU_STACK) o->stack = &p;
  }
  if (first) die(path + ": no PT_LOAD");
  if (!o->dynamic) {
    if (must) die(path + ": no PT_DYNAMIC (a static executable has no libraries to bundle)");
    return nullptr;
  }
  // The dynamic section, read through the segments (its p_offset may not match a stripped copy).
  std::vector<Elf64_Dyn> dyn;
  for (uint64_t va = o->dynamic->p_vaddr;; va += sizeof(Elf64_Dyn)) {
    const uint8_t *p = o->at(va, sizeof(Elf64_Dyn));
    if (!p) die(path + ": PT_DYNAMIC outside the file");
    Elf64_Dyn e;
    memcpy(&e, p, sizeof e);
    if (e.d_tag == DT_NULL) break;
    dyn.push_back(e);
  }
  uint64_t symtab = 0, hash = 0, gnuhash = 0, rela = 0, relasz = 0, jmprel = 0, pltrelsz = 0, relr = 0, relrsz = 0;
  uint64_t versym = 0, verneed = 0, verneednum = 0;
  std::vector<uint64_t> needed_off;
  uint64_t soname_off = UINT64_MAX, rpath_off = 0, runpath_off = 0;
  for (const Elf64_Dyn &e : dyn) {
    uint64_t v = e.d_un.d_val;
    switch (e.d_tag) {
      case DT_NEEDED: needed_off.push_back(v); break;
      case DT_SONAME: soname_off = v; break;
      case DT_RPATH: rpath_off = v; o->has_rpath = true; break;
      case DT_RUNPATH: runpath_off = v; o->has_runpath = true; break;
      case DT_STRTAB: o->strtab_va = v; break;
      case DT_STRSZ: o->strsz = v; break;
      case DT_SYMTAB: symtab = v; break;
      case DT_SYMENT: if (v != sizeof(Elf64_Sym)) die(path + ": unexpected DT_SYMENT"); break;
      case DT_HASH: hash = v; break;
      case DT_GNU_HASH: gnuhash = v; break;
      case DT_RELA: rela = v; break;
      case DT_RELASZ: relasz = v; break;
      case DT_JMPREL: jmprel = v; break;
      case DT_PLTRELSZ: pltrelsz = v; break;
      case DT_PLTREL: if (v != DT_RELA) die(path + ": DT_PLTREL is not DT_RELA"); break;
      case DT_REL: die(path + ": DT_REL relocations are not supported on x86-64");
      case DT_RELR: relr = v; break;
      case DT_RELRSZ: relrsz = v; break;
      case DT_INIT: o->init = v; break;
      case DT_FINI: o->fini = v; break;
      case DT_INIT_ARRAY: o->init_array = v; break;
      case DT_INIT_ARRAYSZ: o->init_arraysz = v; break;
      case DT_FINI_ARRAY: o->fini_array = v; break;
      case DT_FINI_ARRAYSZ: o->fini_arraysz = v; break;
      case DT_PREINIT_ARRAY: case DT_PREINIT_ARRAYSZ: break;  // the input's: kept as they are (executables only)
      case DT_FLAGS: o->flags = v; break;
      case DT_FLAGS_1: o->flags_1 = v; break;
      case DT_SYMBOLIC: o->symbolic = true; break;
      case DT_TEXTREL: o->textrel = true; break;
      case DT_DEBUG: o->has_debug = true; break;
      case DT_VERSYM: versym = v; break;
      case DT_VERDEF: o->verdef_va = v; break;
      case DT_VERDEFNUM: o->verdefnum = v; break;
      case DT_VERNEED: verneed = v; break;
      case DT_VERNEEDNUM: verneednum = v; break;
      case DT_TLSDESC_PLT: case DT_TLSDESC_GOT: die(path + ": TLS descriptors are not supported");
      default: break;
    }
  }
  if (o->flags & DF_SYMBOLIC) o->symbolic = true;
  if (o->flags & DF_TEXTREL) o->textrel = true;
  o->strtab = (const char *)o->at(o->strtab_va, o->strsz);
  if (!o->strtab) die(path + ": DT_STRTAB outside the file");
  for (uint64_t n : needed_off) o->needed.push_back(o->str(n));
  o->soname = soname_off != UINT64_MAX ? o->str(soname_off) : basename_of(path);
  o->has_soname = soname_off != UINT64_MAX;
  if (o->has_rpath) o->rpath = o->str(rpath_off);
  if (o->has_runpath) o->runpath = o->str(runpath_off);

  // The number of dynamic symbols: the section header when there is one, else the hash tables.
  if (o->eh.e_shoff && o->eh.e_shentsize == sizeof(Elf64_Shdr) && o->eh.e_shoff + (uint64_t)o->eh.e_shnum * sizeof(Elf64_Shdr) <= d.size()) {
    for (int i = 0; i < o->eh.e_shnum; i++) {
      Elf64_Shdr s;
      memcpy(&s, d.data() + o->eh.e_shoff + i * sizeof s, sizeof s);
      if (s.sh_type == SHT_DYNSYM && s.sh_addr == symtab) o->nsyms = s.sh_size / sizeof(Elf64_Sym);
    }
  }
  if (!o->nsyms && hash) {
    const uint8_t *p = o->at(hash, 8);
    if (!p) die(path + ": DT_HASH outside the file");
    uint32_t h[2];
    memcpy(h, p, 8);
    o->nsyms = h[1];
  }
  if (!o->nsyms && gnuhash) {
    const uint8_t *p = o->at(gnuhash, 16);
    if (!p) die(path + ": DT_GNU_HASH outside the file");
    uint32_t h[4];
    memcpy(h, p, 16);
    uint64_t buckets = gnuhash + 16 + (uint64_t)h[2] * 8, chains = buckets + (uint64_t)h[0] * 4;
    uint32_t mx = 0;
    for (uint32_t i = 0; i < h[0]; i++) {
      const uint8_t *b = o->at(buckets + i * 4, 4);
      uint32_t v;
      memcpy(&v, b, 4);
      mx = std::max(mx, v);
    }
    if (mx < h[1]) {
      o->nsyms = h[1];
    } else {
      for (;; mx++) {
        const uint8_t *c = o->at(chains + (uint64_t)(mx - h[1]) * 4, 4);
        if (!c) die(path + ": DT_GNU_HASH chain outside the file");
        uint32_t v;
        memcpy(&v, c, 4);
        if (v & 1) break;
      }
      o->nsyms = mx + 1;
    }
  }
  if (o->nsyms) {
    o->syms = (const Elf64_Sym *)o->at(symtab, o->nsyms * sizeof(Elf64_Sym));
    if (!o->syms) die(path + ": DT_SYMTAB outside the file");
  }
  if (versym && o->nsyms) {
    o->versym = (const uint16_t *)o->at(versym, o->nsyms * 2);
    if (!o->versym) die(path + ": DT_VERSYM outside the file");
  }
  for (uint64_t va = o->verdef_va, i = 0; va && i < o->verdefnum; i++) {
    Elf64_Verdef vd;
    const uint8_t *p = o->at(va, sizeof vd);
    if (!p) die(path + ": DT_VERDEF outside the file");
    memcpy(&vd, p, sizeof vd);
    Elf64_Verdaux vda;
    const uint8_t *q = o->at(va + vd.vd_aux, sizeof vda);
    if (!q) die(path + ": DT_VERDEF outside the file");
    memcpy(&vda, q, sizeof vda);
    o->verdef[vd.vd_ndx] = o->str(vda.vda_name);
    if (!vd.vd_next) break;
    va += vd.vd_next;
  }
  for (uint64_t va = verneed, i = 0; va && i < verneednum; i++) {
    Elf64_Verneed vn;
    const uint8_t *p = o->at(va, sizeof vn);
    if (!p) die(path + ": DT_VERNEED outside the file");
    memcpy(&vn, p, sizeof vn);
    std::string file = o->str(vn.vn_file);
    uint64_t a = va + vn.vn_aux;
    for (int j = 0; j < vn.vn_cnt; j++) {
      Elf64_Vernaux vna;
      const uint8_t *q = o->at(a, sizeof vna);
      if (!q) die(path + ": DT_VERNEED outside the file");
      memcpy(&vna, q, sizeof vna);
      o->verneed[vna.vna_other] = {file, o->str(vna.vna_name), vna.vna_flags};
      if (!vna.vna_next) break;
      a += vna.vna_next;
    }
    if (!vn.vn_next) break;
    va += vn.vn_next;
  }
  // Relocations: DT_RELA, DT_JMPREL, and DT_RELR expanded to RELATIVE entries (the addend is the word in place).
  auto add_rela = [&](uint64_t va, uint64_t sz) {
    if (!va || !sz) return;
    const uint8_t *p = o->at(va, sz);
    if (!p) die(path + ": relocations outside the file");
    size_t n = sz / sizeof(Elf64_Rela);
    for (size_t i = 0; i < n; i++) {
      Elf64_Rela r;
      memcpy(&r, p + i * sizeof r, sizeof r);
      o->rel.push_back(r);
    }
  };
  add_rela(rela, relasz);
  add_rela(jmprel, pltrelsz);
  if (relr && relrsz) {
    const uint8_t *p = o->at(relr, relrsz);
    if (!p) die(path + ": DT_RELR outside the file");
    uint64_t where = 0;
    for (size_t i = 0; i < relrsz / 8; i++) {
      uint64_t e;
      memcpy(&e, p + i * 8, 8);
      if (!(e & 1)) {
        o->rel.push_back({e, ELF64_R_INFO(0, R_X86_64_RELATIVE), (int64_t)o->rd64(e)});
        where = e + 8;
      } else {
        for (int b = 1; b < 64; b++)
          if (e >> b & 1) {
            uint64_t a = where + (b - 1) * 8;
            o->rel.push_back({a, ELF64_R_INFO(0, R_X86_64_RELATIVE), (int64_t)o->rd64(a)});
          }
        where += 63 * 8;
      }
    }
  }
  for (size_t i = 0; i < o->rel.size(); i++) o->rel_at.emplace(o->rel[i].r_offset, i);
  objs.push_back(std::move(o));
  return objs.back().get();
}

// --- finding libraries --------------------------------------------------------------------------------------------

std::vector<std::string> ldso_conf_dirs;
void read_ldso_conf(const std::string &file, int depth) {
  if (depth > 8) return;
  FILE *f = fopen(file.c_str(), "r");
  if (!f) return;
  char line[4096];
  while (fgets(line, sizeof line, f)) {
    std::string s = line;
    size_t h = s.find('#');
    if (h != std::string::npos) s.resize(h);
    while (!s.empty() && strchr(" \t\r\n", s.back())) s.pop_back();
    size_t b = s.find_first_not_of(" \t");
    if (b == std::string::npos) continue;
    s = s.substr(b);
    if (s.rfind("include", 0) == 0 && s.size() > 7 && strchr(" \t", s[7])) {
      std::string pat = s.substr(s.find_first_not_of(" \t", 7));
      if (pat[0] != '/') pat = dirname_of(file) + "/" + pat;
      glob_t g;
      if (glob(pat.c_str(), 0, nullptr, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) read_ldso_conf(g.gl_pathv[i], depth + 1);
        globfree(&g);
      }
    } else if (s[0] == '/') {
      ldso_conf_dirs.push_back(s);
    }
  }
  fclose(f);
}

bool usable(const std::string &p) {
  FILE *f = fopen(p.c_str(), "rb");
  if (!f) return false;
  unsigned char h[20];
  bool ok = fread(h, 1, sizeof h, f) == sizeof h && memcmp(h, ELFMAG, SELFMAG) == 0 && h[EI_CLASS] == ELFCLASS64 &&
            (h[18] | h[19] << 8) == EM_X86_64;
  fclose(f);
  return ok;
}

std::string expand_origin(const std::string &dir, const Obj *from) {
  std::string r = dir;
  char real[PATH_MAX];
  std::string origin = realpath(from->path.c_str(), real) ? dirname_of(real) : dirname_of(from->path);
  for (const char *tok : {"${ORIGIN}", "$ORIGIN"}) {
    size_t p;
    while ((p = r.find(tok)) != std::string::npos) r.replace(p, strlen(tok), origin);
  }
  return r;
}

std::string find_lib(const std::string &name, const Obj *from) {
  if (name.find('/') != std::string::npos) return usable(name) ? name : "";
  std::vector<std::string> dirs;
  auto add = [&](const std::string &list, const Obj *o) {
    for (const std::string &d : split(list, ':')) dirs.push_back(o ? expand_origin(d, o) : d);
  };
  if (!from->has_runpath) {
    // DT_RPATH of the loading object, then of the input (ld.so walks the chain of loaders; the input ends it).
    add(from->rpath, from);
    if (!objs.empty() && objs[0].get() != from && !objs[0]->has_runpath) add(objs[0]->rpath, objs[0].get());
  }
  if (const char *e = getenv("LD_LIBRARY_PATH")) add(e, nullptr);
  add(from->runpath, from);
  for (const std::string &d : opt_libdirs) dirs.push_back(d);
  for (const std::string &d : ldso_conf_dirs) dirs.push_back(d);
  for (const char *d : {"/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib64", "/lib", "/usr/lib"})
    dirs.push_back(d);
  for (const std::string &d : dirs) {
    std::string p = d + "/" + name;
    if (usable(p)) return p;
  }
  return "";
}

bool matches(const std::vector<std::string> &list, const Obj *o) {
  for (const std::string &n : list)
    if (n == o->soname || n == basename_of(o->path) || n == o->path || o->soname.rfind(n + ".so", 0) == 0) return true;
  return false;
}

// --- symbol resolution --------------------------------------------------------------------------------------------

struct Def {
  Obj *obj = nullptr;
  size_t idx = 0;
  bool plt_canonical = false;  // an undefined function of a position-dependent input with a PLT address
};
std::vector<Obj *> scope;  // lookup order: the input, the bundled libraries, then the excluded ones
std::unordered_map<std::string, std::vector<Def>> defs;

std::string ref_version(const Obj *u, size_t i) {
  if (!u->versym) return "";
  int v = u->versym[i] & 0x7fff;
  if (v < 2) return "";
  if (u->defined(i)) {
    auto it = u->verdef.find(v);
    return it == u->verdef.end() ? "" : it->second;
  }
  auto it = u->verneed.find(v);
  return it == u->verneed.end() ? "" : it->second.name;
}

bool version_ok(const Obj *d, size_t j, const std::string &want) {
  if (!d->versym) return true;
  uint16_t raw = d->versym[j];
  int v = raw & 0x7fff;
  if (want.empty()) return v < 2 || !(raw & 0x8000);  // an unversioned reference takes the default version
  if (v < 2) return true;
  auto it = d->verdef.find(v);
  if (it != d->verdef.end()) return it->second == want;
  // A definition made by a copy relocation (or a canonical PLT entry) carries the version it needed.
  auto nt = d->verneed.find(v);
  return nt != d->verneed.end() && nt->second.name == want;
}

void index_defs() {
  for (Obj *o : scope) {
    bool pde = o->is_main && o->eh.e_type == ET_EXEC;
    for (size_t i = 1; i < o->nsyms; i++) {
      const Elf64_Sym &s = o->syms[i];
      int bind = ELF64_ST_BIND(s.st_info), type = ELF64_ST_TYPE(s.st_info), vis = ELF64_ST_VISIBILITY(s.st_other);
      if (bind != STB_GLOBAL && bind != STB_WEAK && bind != STB_GNU_UNIQUE) continue;
      if (vis == STV_HIDDEN || vis == STV_INTERNAL || type == STT_SECTION || type == STT_FILE) continue;
      if (s.st_shndx == SHN_UNDEF) {
        if (pde && type == STT_FUNC && s.st_value) defs[o->symname(i)].push_back({o, i, true});
        continue;
      }
      defs[o->symname(i)].push_back({o, i, false});
    }
  }
}

// Where ld.so would bind symbol i of unit u (cls_plt: a PLT slot, which a canonical PLT entry does not satisfy;
// skip_main: a copy relocation, which looks past the input).
Def resolve(Obj *u, size_t i, bool cls_plt, bool skip_main) {
  const Elf64_Sym &s = u->syms[i];
  int bind = ELF64_ST_BIND(s.st_info), vis = ELF64_ST_VISIBILITY(s.st_other);
  if (u->defined(i) && !skip_main && (bind == STB_LOCAL || vis != STV_DEFAULT || u->symbolic)) return {u, i, false};
  auto it = defs.find(u->symname(i));
  if (it == defs.end()) return {};
  std::string want = ref_version(u, i);
  for (const Def &d : it->second) {
    if (skip_main && d.obj->is_main) continue;
    if (d.plt_canonical && cls_plt) continue;
    if (!version_ok(d.obj, d.idx, want)) continue;
    return d;
  }
  return {};
}

// --- output -------------------------------------------------------------------------------------------------------

struct StrTab {
  std::string data = std::string(1, '\0');
  std::unordered_map<std::string, uint32_t> at;
  uint32_t add(const std::string &s) {
    auto it = at.find(s);
    if (it != at.end()) return it->second;
    uint32_t off = data.size();
    data += s;
    data += '\0';
    at.emplace(s, off);
    return off;
  }
} dynstr;

std::vector<Elf64_Sym> osyms(1);
std::vector<uint16_t> oversym(1, 0);
std::set<std::string> exported;
std::map<std::pair<const Obj *, size_t>, uint32_t> export_of;  // exported definition -> output symbol
// A shared object output keeps a reference to one of its exported default-visibility definitions symbolic, as the
// linker left it, so the program can still interpose the symbol or take it by a copy relocation. An executable is
// first in the lookup scope, so there such a reference is bound when bundling.
bool preemptible_exports = false;
std::map<std::string, uint32_t> undef_at;  // name \0 file \0 version -> output symbol
struct NeedOut {
  std::string file;
  std::vector<std::pair<std::string, uint16_t>> vers;  // version name, flags
  std::vector<uint16_t> idx;
};
std::vector<NeedOut> oneed;
uint16_t next_ver = 2;
std::map<std::pair<std::string, std::string>, uint16_t> need_idx;

uint16_t need_version(const std::string &file, const std::string &name, uint16_t flags) {
  auto key = std::make_pair(file, name);
  auto it = need_idx.find(key);
  if (it != need_idx.end()) return it->second;
  NeedOut *n = nullptr;
  for (NeedOut &x : oneed)
    if (x.file == file) n = &x;
  if (!n) {
    oneed.push_back({file, {}, {}});
    n = &oneed.back();
  }
  uint16_t v = next_ver++;
  n->vers.push_back({name, flags});
  n->idx.push_back(v);
  need_idx[key] = v;
  return v;
}

// The output symbol for an unresolved or external reference, symbol i of unit u.
uint32_t ext_sym(Obj *u, size_t i) {
  const Elf64_Sym &s = u->syms[i];
  std::string name = u->symname(i), file, ver;
  uint16_t vflags = 0;
  if (u->versym && !u->defined(i)) {
    int v = u->versym[i] & 0x7fff;
    auto it = u->verneed.find(v);
    if (v >= 2 && it != u->verneed.end()) {
      // A version needed from a library that is now bundled cannot be checked against it at run time.
      bool gone = false;
      for (auto &o : objs)
        if (o->bundled && o->soname == it->second.file) gone = true;
      if (!gone) file = it->second.file, ver = it->second.name, vflags = it->second.flags;
    }
  }
  std::string key = name + '\0' + file + '\0' + ver;
  auto it = undef_at.find(key);
  int bind = ELF64_ST_BIND(s.st_info) == STB_WEAK ? STB_WEAK : STB_GLOBAL;
  if (it != undef_at.end()) {
    Elf64_Sym &o = osyms[it->second];
    if (bind == STB_GLOBAL) o.st_info = ELF64_ST_INFO(STB_GLOBAL, ELF64_ST_TYPE(o.st_info));
    return it->second;
  }
  Elf64_Sym o{};
  o.st_name = dynstr.add(name);
  o.st_info = ELF64_ST_INFO(bind, ELF64_ST_TYPE(s.st_info));
  o.st_other = STV_DEFAULT;
  osyms.push_back(o);
  oversym.push_back(ver.empty() ? 1 : need_version(file, ver, vflags));
  undef_at[key] = osyms.size() - 1;
  return osyms.size() - 1;
}

struct ORel {
  uint64_t off;
  uint32_t type, sym;
  int64_t addend;
};
std::vector<ORel> rel_relative, rel_other, rel_irel;
std::vector<std::pair<uint64_t, uint64_t>> patches;  // output address, 8-byte value written into the file
std::vector<std::pair<uint64_t, uint32_t>> patches32;
struct Copy {
  uint64_t dst, src, size;
};
std::vector<Copy> copies;
bool static_tls = false;
uint64_t tls_image_va = 0;
bool merge_tls = false;

uint64_t out_addr(const Obj *u, uint64_t va) {
  if (merge_tls && u->tls && va >= u->tls->p_vaddr && va < u->tls->p_vaddr + u->tls->p_filesz)
    return tls_image_va + u->tls_off + (va - u->tls->p_vaddr);
  return va + u->base;
}
uint64_t sym_value(const Def &d) {
  const Elf64_Sym &s = d.obj->syms[d.idx];
  if (s.st_shndx == SHN_ABS) return s.st_value;
  if (ELF64_ST_TYPE(s.st_info) == STT_TLS) return s.st_value + d.obj->tls_off;
  return s.st_value + d.obj->base;
}

std::string rname(uint32_t t) {
  switch (t) {
    case R_X86_64_32: return "R_X86_64_32";
    case R_X86_64_32S: return "R_X86_64_32S";
    case R_X86_64_16: return "R_X86_64_16";
    case R_X86_64_8: return "R_X86_64_8";
    case R_X86_64_TLSDESC: return "R_X86_64_TLSDESC";
    case R_X86_64_TPOFF32: return "R_X86_64_TPOFF32";
    case R_X86_64_DTPOFF32: return "R_X86_64_DTPOFF32";
    default: return "relocation type " + std::to_string(t);
  }
}

// The output symbol a reference to definition d stays symbolic against (see preemptible_exports), or -1.
int64_t preempt(const Def &d) {
  if (!preemptible_exports || d.plt_canonical || d.obj->symbolic) return -1;
  if (ELF64_ST_VISIBILITY(d.obj->syms[d.idx].st_other) != STV_DEFAULT) return -1;
  auto it = export_of.find({d.obj, d.idx});
  return it == export_of.end() ? -1 : (int64_t)it->second;
}

// One relocation of unit u, applied at output address off.
void translate(Obj *u, const Elf64_Rela &r, uint64_t off) {
  uint32_t type = ELF64_R_TYPE(r.r_info);
  size_t si = ELF64_R_SYM(r.r_info);
  int64_t a = r.r_addend;
  if (si >= u->nsyms && si) die(u->path + ": relocation symbol out of range");
  auto where = [&]() { return u->path + ": " + rname(type) + " at " + hex(r.r_offset) + (si ? " (" + u->symname(si) + ")" : ""); };
  auto unresolved = [&](const char *what) {
    // Only an executable is complete: a shared object's undefined symbols are the program's to define.
    static std::set<std::string> said;
    if (objs[0]->exe() && ELF64_ST_BIND(u->syms[si].st_info) != STB_WEAK && said.insert(u->symname(si)).second)
      fprintf(stderr, "nfcbundle: warning: %s: %s is not defined by any loaded object; it stays a %s reference\n",
              u->path.c_str(), u->symname(si).c_str(), what);
  };
  switch (type) {
    case R_X86_64_NONE: return;
    case R_X86_64_RELATIVE: rel_relative.push_back({off, R_X86_64_RELATIVE, 0, a + (int64_t)u->base}); return;
    case R_X86_64_IRELATIVE: rel_irel.push_back({off, R_X86_64_IRELATIVE, 0, a + (int64_t)u->base}); return;
    case R_X86_64_64: case R_X86_64_GLOB_DAT: case R_X86_64_JUMP_SLOT: {
      if (!si) {  // the null symbol: load base plus addend
        rel_relative.push_back({off, R_X86_64_RELATIVE, 0, a + (int64_t)u->base});
        return;
      }
      Def d = resolve(u, si, type == R_X86_64_JUMP_SLOT, false);
      if (!d.obj) {
        if (ELF64_ST_BIND(u->syms[si].st_info) == STB_WEAK) {
          // A weak reference nothing defines is zero; an excluded library may still define it later (dlopen with
          // RTLD_GLOBAL), so it stays symbolic, as the linker left it.
          rel_other.push_back({off, type, ext_sym(u, si), a});
          return;
        }
        unresolved("symbolic");
        rel_other.push_back({off, type, ext_sym(u, si), a});
        return;
      }
      if (!d.obj->bundled) {
        rel_other.push_back({off, type, ext_sym(u, si), a});
        return;
      }
      if (int64_t x = preempt(d); x >= 0) {
        rel_other.push_back({off, type, (uint32_t)x, a});
        return;
      }
      const Elf64_Sym &s = d.obj->syms[d.idx];
      if (ELF64_ST_TYPE(s.st_info) == STT_TLS) die(where() + ": an address relocation against a TLS symbol");
      if (s.st_shndx == SHN_ABS) {
        patches.push_back({off, s.st_value + a});
      } else if (ELF64_ST_TYPE(s.st_info) == STT_GNU_IFUNC && !d.plt_canonical) {
        if (a) die(where() + ": an addend on a reference to an IFUNC");
        rel_irel.push_back({off, R_X86_64_IRELATIVE, 0, (int64_t)sym_value(d)});
      } else {
        rel_relative.push_back({off, R_X86_64_RELATIVE, 0, (int64_t)sym_value(d) + a});
      }
      return;
    }
    case R_X86_64_COPY: {
      Def d = resolve(u, si, false, true);
      if (d.obj && d.obj->bundled) {
        copies.push_back({off, sym_value(d), u->syms[si].st_size});
      } else {
        // The copy names the input's own definition (its size is checked against the source's); the symbol index is
        // the input's until the exported symbols are numbered.
        if (!d.obj) unresolved("copy");
        rel_other.push_back({off, type, export_of.at({u, si}), a});
      }
      return;
    }
    case R_X86_64_DTPMOD64: {
      if (!si) {
        // A local-dynamic (or local general-dynamic) GOT pair: the module, then an offset in the module's block that
        // the linker wrote in place. The unit's block now starts at tls_off in the merged block.
        rel_other.push_back({off, type, 0, 0});
        if (!u->rel_at.count(r.r_offset + 8)) patches.push_back({out_addr(u, r.r_offset + 8), u->rd64(r.r_offset + 8) + u->tls_off});
        return;
      }
      Def d = resolve(u, si, false, false);
      if (int64_t x = d.obj && d.obj->bundled ? preempt(d) : -1; x >= 0) rel_other.push_back({off, type, (uint32_t)x, a});
      else if (d.obj && d.obj->bundled) rel_other.push_back({off, type, 0, 0});
      else {
        if (!d.obj) unresolved("TLS");
        rel_other.push_back({off, type, ext_sym(u, si), a});
      }
      return;
    }
    case R_X86_64_DTPOFF64: {
      if (!si) {
        patches.push_back({off, (uint64_t)a + u->tls_off});
        return;
      }
      Def d = resolve(u, si, false, false);
      if (int64_t x = d.obj && d.obj->bundled ? preempt(d) : -1; x >= 0) rel_other.push_back({off, type, (uint32_t)x, a});
      else if (d.obj && d.obj->bundled) patches.push_back({off, sym_value(d) + a});
      else {
        if (!d.obj) unresolved("TLS");
        rel_other.push_back({off, type, ext_sym(u, si), a});
      }
      return;
    }
    case R_X86_64_TPOFF64: {
      if (!si) {
        rel_other.push_back({off, type, 0, a + (int64_t)u->tls_off});
        static_tls = true;
        return;
      }
      Def d = resolve(u, si, false, false);
      if (int64_t x = d.obj && d.obj->bundled ? preempt(d) : -1; x >= 0) {
        rel_other.push_back({off, type, (uint32_t)x, a});
        static_tls = true;
      } else if (d.obj && d.obj->bundled) {
        rel_other.push_back({off, type, 0, (int64_t)sym_value(d) + a});
        static_tls = true;
      } else {
        if (!d.obj) unresolved("TLS");
        rel_other.push_back({off, type, ext_sym(u, si), a});
      }
      return;
    }
    case R_X86_64_PC32: case R_X86_64_PC64: case R_X86_64_SIZE64: case R_X86_64_SIZE32: {
      Def d = si ? resolve(u, si, false, false) : Def{};
      if (d.obj && d.obj->bundled) {
        const Elf64_Sym &s = d.obj->syms[d.idx];
        int64_t v = type == R_X86_64_SIZE64 || type == R_X86_64_SIZE32 ? (int64_t)s.st_size + a : (int64_t)sym_value(d) + a - (int64_t)off;
        if (type == R_X86_64_PC64 || type == R_X86_64_SIZE64) patches.push_back({off, (uint64_t)v});
        else {
          if (v != (int32_t)v) die(where() + ": value out of range");
          patches32.push_back({off, (uint32_t)v});
        }
      } else if (si) {
        rel_other.push_back({off, type, ext_sym(u, si), a});
      } else {
        die(where() + ": unsupported without a symbol");
      }
      return;
    }
    default: die(where() + ": not supported");
  }
}

void put(std::vector<uint8_t> &b, size_t off, const void *p, size_t n) {
  if (off + n > b.size()) b.resize(off + n);
  memcpy(b.data() + off, p, n);
}
template <class T> void put(std::vector<uint8_t> &b, size_t off, const T &v) { put(b, off, &v, sizeof v); }

uint32_t elf_hash(const char *s) {
  uint32_t h = 0, g;
  while (*s) {
    h = (h << 4) + (unsigned char)*s++;
    if ((g = h & 0xf0000000)) h ^= g >> 24;
    h &= ~g;
  }
  return h;
}

// .eh_frame_hdr pointer encodings (DW_EH_PE_*) that linkers write.
bool read_enc(const Obj *u, uint64_t va, int enc, uint64_t datarel, uint64_t &val, uint64_t &len) {
  if (enc == 0xff) return false;
  const uint8_t *p;
  int64_t v;
  switch (enc & 0x0f) {
    case 0x00: case 0x04: case 0x0c: len = 8; break;
    case 0x03: case 0x0b: len = 4; break;
    case 0x02: case 0x0a: len = 2; break;
    default: die(u->path + ": .eh_frame_hdr encoding " + hex(enc) + " not supported");
  }
  p = u->at(va, len);
  if (!p) die(u->path + ": .eh_frame_hdr outside the file");
  if (len == 8) {
    uint64_t x;
    memcpy(&x, p, 8);
    v = (int64_t)x;
  } else if (len == 4) {
    uint32_t x;
    memcpy(&x, p, 4);
    v = (enc & 0x08) ? (int64_t)(int32_t)x : (int64_t)x;
  } else {
    uint16_t x;
    memcpy(&x, p, 2);
    v = (enc & 0x08) ? (int64_t)(int16_t)x : (int64_t)x;
  }
  switch (enc & 0x70) {
    case 0x00: break;
    case 0x10: v += (int64_t)va; break;
    case 0x30: v += (int64_t)datarel; break;
    default: die(u->path + ": .eh_frame_hdr encoding " + hex(enc) + " not supported");
  }
  val = (uint64_t)v;
  return true;
}

// --stubs: a library that the output now contains, as an empty shared object with the same DT_SONAME and version
// definitions and no symbols. A plugin that names the library in DT_NEEDED (libtorch_cuda_linalg.so naming
// libtorch_cpu.so, a ruby extension naming libruby.so) loads the stub instead of a second copy, and its symbols bind
// to the output's exports: through the global scope when the output is the program, through the stub's DT_NEEDED
// (the output's own soname, `owner`) when it is a shared object.
// How the output finds the stub directory: $ORIGIN-relative when it is the output's directory or below it, else
// absolute.
std::string stubs_path(const std::string &dir, const std::string &out) {
  char a[PATH_MAX], b[PATH_MAX];
  mkdir(dir.c_str(), 0755);
  std::string od = dirname_of(out);
  if (!realpath(dir.c_str(), a) || !realpath(od.c_str(), b)) return dir;
  std::string s = a, o = b;
  if (s == o) return "$ORIGIN";
  if (s.compare(0, o.size() + 1, o + "/") == 0) return "$ORIGIN/" + s.substr(o.size() + 1);
  return s;
}

// No stub for a library whose handle is used with dlsym: dlsym searches only the handle's object and its
// dependencies, so it would find the stub's nothing. glibc dlopens libgcc_s.so.1 and looks up _Unwind_Backtrace and
// _Unwind_ForcedUnwind in it (backtrace, pthread_cancel); without a stub it loads its own copy, as it would for a
// program that does not need libgcc_s.
bool stubbable(const Obj *u) { return u->soname.rfind("libgcc_s.so", 0) != 0; }

void write_stub(const Obj *u, const std::string &dir, const std::string &owner) {
  StrTab st;
  uint32_t soname = st.add(u->soname), need = owner.empty() ? 0 : st.add(owner);
  std::vector<std::pair<int, std::string>> vers(u->verdef.begin(), u->verdef.end());
  std::vector<uint32_t> vnames;
  for (auto &v : vers) vnames.push_back(st.add(v.second));
  const uint64_t ph_off = sizeof(Elf64_Ehdr), str_off = ph_off + 2 * sizeof(Elf64_Phdr);
  uint64_t sym_off = align_up(str_off + st.data.size(), 8), hash_off = sym_off + sizeof(Elf64_Sym);
  uint64_t versym_off = hash_off + 16, verdef_off = align_up(versym_off + 2, 8);
  uint64_t dyn_off = align_up(verdef_off + vers.size() * (sizeof(Elf64_Verdef) + sizeof(Elf64_Verdaux)), 8);
  std::vector<Elf64_Dyn> dyn;
  if (!owner.empty()) dyn.push_back({DT_NEEDED, {need}});
  dyn.push_back({DT_SONAME, {soname}});
  dyn.push_back({DT_STRTAB, {str_off}});
  dyn.push_back({DT_STRSZ, {st.data.size()}});
  dyn.push_back({DT_SYMTAB, {sym_off}});
  dyn.push_back({DT_SYMENT, {sizeof(Elf64_Sym)}});
  dyn.push_back({DT_HASH, {hash_off}});
  if (!vers.empty()) {
    dyn.push_back({DT_VERSYM, {versym_off}});
    dyn.push_back({DT_VERDEF, {verdef_off}});
    dyn.push_back({DT_VERDEFNUM, {vers.size()}});
  }
  dyn.push_back({DT_NULL, {0}});
  uint64_t end = dyn_off + dyn.size() * sizeof(Elf64_Dyn);
  std::vector<uint8_t> b(end, 0);
  Elf64_Ehdr eh{};
  memcpy(eh.e_ident, ELFMAG, SELFMAG);
  eh.e_ident[EI_CLASS] = ELFCLASS64;
  eh.e_ident[EI_DATA] = ELFDATA2LSB;
  eh.e_ident[EI_VERSION] = EV_CURRENT;
  eh.e_type = ET_DYN;
  eh.e_machine = EM_X86_64;
  eh.e_version = EV_CURRENT;
  eh.e_phoff = ph_off;
  eh.e_ehsize = sizeof eh;
  eh.e_phentsize = sizeof(Elf64_Phdr);
  eh.e_phnum = 2;
  eh.e_shentsize = sizeof(Elf64_Shdr);
  put(b, 0, eh);
  Elf64_Phdr load{}, dynp{};
  load.p_type = PT_LOAD;
  load.p_flags = PF_R | PF_W;  // ld.so may adjust a writable dynamic section in place
  load.p_filesz = load.p_memsz = end;
  load.p_align = PAGE;
  dynp.p_type = PT_DYNAMIC;
  dynp.p_flags = PF_R | PF_W;
  dynp.p_offset = dynp.p_vaddr = dynp.p_paddr = dyn_off;
  dynp.p_filesz = dynp.p_memsz = end - dyn_off;
  dynp.p_align = 8;
  put(b, ph_off, load);
  put(b, ph_off + sizeof load, dynp);
  put(b, str_off, st.data.data(), st.data.size());
  uint32_t hash[4] = {1, 1, 0, 0};  // one bucket, the null symbol only
  put(b, hash_off, hash, sizeof hash);
  for (size_t i = 0; i < vers.size(); i++) {
    Elf64_Verdef vd{};
    vd.vd_version = VER_DEF_CURRENT;
    vd.vd_flags = vers[i].first == 1 ? VER_FLG_BASE : 0;
    vd.vd_ndx = vers[i].first;
    vd.vd_cnt = 1;
    vd.vd_hash = elf_hash(vers[i].second.c_str());
    vd.vd_aux = sizeof(Elf64_Verdef);
    vd.vd_next = i + 1 < vers.size() ? sizeof(Elf64_Verdef) + sizeof(Elf64_Verdaux) : 0;
    Elf64_Verdaux va{vnames[i], 0};
    uint64_t at = verdef_off + i * (sizeof(Elf64_Verdef) + sizeof(Elf64_Verdaux));
    put(b, at, vd);
    put(b, at + sizeof vd, va);
  }
  put(b, dyn_off, dyn.data(), dyn.size() * sizeof(Elf64_Dyn));
  // Named as the libraries ask for it; ld.so also matches a later request for the soname against the loaded stub.
  std::string path = dir + "/" + u->needed_as, tmp = path + ".tmp";
  FILE *f = fopen(tmp.c_str(), "wb");
  if (!f || fwrite(b.data(), 1, b.size(), f) != b.size() || fclose(f) != 0) die("cannot write " + tmp);
  chmod(tmp.c_str(), 0755);
  if (rename(tmp.c_str(), path.c_str()) != 0) die("cannot rename " + tmp + " to " + path + ": " + strerror(errno));
  note("stub " + path);
}

void usage() {
  fprintf(stderr,
          "usage: nfcbundle [-v] [--list] [-L DIR]... [--exclude NAME]... [--only NAME]... [--add NAME]... [--export=all|main]\n"
          "                 [--runpath LIST | --rpath LIST] [--stubs DIR] IN -o OUT\n"
          "  copies the shared libraries IN needs (DT_NEEDED, recursively) into OUT; the glibc libraries stay external\n"
          "  --exclude NAME  keep NAME (a soname, a file name, or a soname stem such as libfoo) external\n"
          "  --only NAME     bundle only the named libraries (repeatable)\n"
          "  --add NAME      bundle NAME (a soname or a path) as if IN needed it\n"
          "  --list          print each library and whether it would be bundled, write nothing\n"
          "  --export=main   export only IN's own dynamic symbols (default all: the bundled libraries' too)\n"
          "  --runpath LIST  the output's DT_RUNPATH (default: IN's, then the bundled libraries' with $ORIGIN resolved)\n"
          "  --rpath LIST    the same as DT_RPATH, which ld.so also searches for what the output's plugins need\n"
          "  --stubs DIR     also write an empty stand-in (same soname and versions) for each bundled library into DIR, for\n"
          "                  plugins that name one in DT_NEEDED\n");
  exit(2);
}

}  // namespace

int main(int argc, char **argv) {
  std::string in, out;
  bool list_only = false;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto val = [&](const std::string &opt) -> std::string {
      if (a.size() > opt.size() && a.compare(0, opt.size() + 1, opt + "=") == 0) return a.substr(opt.size() + 1);
      if (i + 1 >= argc) usage();
      return argv[++i];
    };
    if (a == "-o") out = val("-o");
    else if (a == "-v") verbose = true;
    else if (a == "--list") list_only = true;
    else if (a == "-L") opt_libdirs.push_back(val("-L"));
    else if (a.rfind("-L", 0) == 0) opt_libdirs.push_back(a.substr(2));
    else if (a == "--exclude" || a.rfind("--exclude=", 0) == 0) opt_exclude.push_back(val("--exclude"));
    else if (a == "--only" || a.rfind("--only=", 0) == 0) opt_only.push_back(val("--only"));
    else if (a == "--add" || a.rfind("--add=", 0) == 0) opt_add.push_back(val("--add"));
    else if (a == "--export=all") export_all = true;
    else if (a == "--export=main") export_all = false;
    else if (a == "--runpath" || a.rfind("--runpath=", 0) == 0) opt_runpath = val("--runpath"), runpath_set = true, rpath_kind = false;
    else if (a == "--rpath" || a.rfind("--rpath=", 0) == 0) opt_runpath = val("--rpath"), runpath_set = true, rpath_kind = true;
    else if (a == "--stubs" || a.rfind("--stubs=", 0) == 0) opt_stubs = val("--stubs");
    else if (a == "-h" || a == "--help") usage();
    else if (a[0] == '-') { fprintf(stderr, "nfcbundle: unknown option %s\n", a.c_str()); usage(); }
    else if (in.empty()) in = a;
    else usage();
  }
  if (in.empty() || (out.empty() && !list_only)) usage();
  read_ldso_conf("/etc/ld.so.conf", 0);

  // Load the input and everything it needs, breadth first (ld.so's load order).
  Obj *mainobj = load(in, true);
  mainobj->is_main = true;
  // --add: libraries the input does not name in DT_NEEDED but should carry, as if it did (libtorch_cuda.so, whose
  // static constructors register the CUDA backend, is dropped by a link with --as-needed). Searched like the input's own.
  for (const std::string &n : opt_add) mainobj->needed.push_back(n);
  mainobj->bundled = true;
  std::map<std::string, Obj *> by_name;
  by_name[mainobj->soname] = mainobj;
  std::vector<std::string> missing;
  for (size_t qi = 0; qi < objs.size(); qi++) {
    Obj *o = objs[qi].get();
    for (const std::string &n : o->needed) {
      std::string key = n.find('/') != std::string::npos ? basename_of(n) : n;
      auto it = by_name.find(key);
      if (it != by_name.end()) {
        o->deps.push_back(it->second);
        continue;
      }
      std::string p = find_lib(n, o);
      Obj *d = p.empty() ? nullptr : load(p, false);
      if (!d) {
        missing.push_back(n);
        by_name[key] = nullptr;
        continue;
      }
      o = objs[qi].get();  // load() may have moved the vector
      by_name[key] = d;
      d->needed_as = key;
      if (d->soname != key) by_name[d->soname] = d;
      o->deps.push_back(d);
    }
  }
  for (const std::string &n : missing) {
    if (is_system(n)) fprintf(stderr, "nfcbundle: warning: %s not found; it stays a DT_NEEDED of the output\n", n.c_str());
    else die(n + ": not found (needed by the input or one of its libraries); give its directory with -L");
  }
  // Which libraries are bundled: not glibc or a GPU driver, not excluded, in --only when given, and not needed by an excluded one.
  for (size_t i = 1; i < objs.size(); i++) {
    Obj *o = objs[i].get();
    o->excluded = is_system(o->soname) || matches(opt_exclude, o) || (!opt_only.empty() && !matches(opt_only, o));
  }
  for (bool changed = true; changed;) {
    changed = false;
    for (auto &o : objs)
      if (o->excluded)
        for (Obj *d : o->deps)
          if (!d->excluded && !d->is_main) {
            d->excluded = true;
            changed = true;
            note(d->soname + " stays external: " + o->soname + " (excluded) needs it");
          }
  }
  std::vector<Obj *> units{mainobj};
  for (size_t i = 1; i < objs.size(); i++)
    if (!objs[i]->excluded) {
      objs[i]->bundled = true;
      units.push_back(objs[i].get());
    }
  if (list_only) {
    for (size_t i = 1; i < objs.size(); i++)
      printf("%s %s %s\n", objs[i]->bundled ? "bundle" : "keep", objs[i]->soname.c_str(), objs[i]->path.c_str());
    return 0;
  }
  for (Obj *u : units)
    if (u != mainobj && u->eh.e_type != ET_DYN) die(u->path + ": a library that is not ET_DYN");
  if (units.size() == 1) {
    // Nothing to bundle (only glibc is needed): the input as it is.
    note("no library to bundle; " + out + " is a copy of " + in);
    std::string tmp = out + ".tmp";
    FILE *f = fopen(tmp.c_str(), "wb");
    if (!f || fwrite(mainobj->d.data(), 1, mainobj->d.size(), f) != mainobj->d.size() || fclose(f) != 0)
      die("cannot write " + tmp);
    chmod(tmp.c_str(), 0755);
    if (rename(tmp.c_str(), out.c_str()) != 0) die("cannot rename " + tmp + " to " + out + ": " + strerror(errno));
    return 0;
  }
  // A program started by the crt code of glibc before 2.34 (__libc_start_main@GLIBC_2.2.5) runs its init array from
  // that code, not from DT_INIT_ARRAY, so the bundled libraries' constructors would never run.
  if (mainobj->exe() && mainobj->versym)
    for (size_t i = 1; i < mainobj->nsyms; i++)
      if (!mainobj->defined(i) && mainobj->symname(i) == "__libc_start_main" && ref_version(mainobj, i) == "GLIBC_2.2.5")
        die(in + ": linked with the startup code of glibc before 2.34 (__libc_start_main@GLIBC_2.2.5), which runs "
            "the program's init array itself; the bundled libraries' constructors would not run. Relink it against "
            "glibc 2.34 or later");
  for (Obj *u : units) note(std::string(u->is_main ? "input " : "bundle ") + u->soname + " (" + u->path + ")");
  preemptible_exports = !mainobj->exe();
  for (Obj *o : units) scope.push_back(o);
  for (auto &o : objs)
    if (!o->bundled) scope.push_back(o.get());
  index_defs();

  // A copy relocation whose source is bundled is done here, into the input's bss: that part of its segment then has
  // to be in the file.
  bool materialize = false;
  for (const Elf64_Rela &r : mainobj->rel)
    if (ELF64_R_TYPE(r.r_info) == R_X86_64_COPY) {
      Def d = resolve(mainobj, ELF64_R_SYM(r.r_info), false, true);
      if (d.obj && d.obj->bundled) materialize = true;
    }

  // Addresses: each library above the previous unit, at its own alignment.
  std::vector<Elf64_Phdr> mph = mainobj->ph;  // the input's program headers, possibly with a materialized bss
  uint64_t main_end = 0;
  const Elf64_Phdr *last_load = nullptr;
  for (const Elf64_Phdr &p : mainobj->ph)
    if (p.p_type == PT_LOAD && (!last_load || p.p_offset > last_load->p_offset)) last_load = &p;
  if (materialize) {
    for (Elf64_Phdr &p : mph)
      if (p.p_type == PT_LOAD && p.p_offset == last_load->p_offset) p.p_filesz = p.p_memsz;
  }
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_LOAD) main_end = std::max(main_end, p.p_offset + p.p_filesz);
  // .eh_frame_hdr: the search tables of all units, in one table (placed below, once the size is known).
  struct FdeEnt {
    Obj *u;
    uint64_t loc, fde;  // unit addresses until the layout is known, output addresses after
  };
  std::vector<FdeEnt> fdes;
  uint64_t eh_frame_va = 0;
  Obj *eh_frame_unit = nullptr;
  for (Obj *u : units) {
    if (!u->ehframe) {
      bool code = false;  // a data-only library (libicudata) has nothing to unwind
      for (const Elf64_Phdr &p : u->ph)
        if (p.p_type == PT_LOAD && (p.p_flags & PF_X) && p.p_filesz) code = true;
      if (!u->is_main && code) fprintf(stderr, "nfcbundle: warning: %s has no PT_GNU_EH_FRAME; its code cannot be unwound\n", u->path.c_str());
      continue;
    }
    uint64_t h = u->ehframe->p_vaddr;
    const uint8_t *p = u->at(h, 4);
    if (!p || p[0] != 1) die(u->path + ": unexpected .eh_frame_hdr");
    uint64_t pos = h + 4, len, ehf, n;
    if (read_enc(u, pos, p[1], h, ehf, len)) {
      pos += len;
      if (!eh_frame_unit) eh_frame_va = ehf, eh_frame_unit = u;
    }
    if (!read_enc(u, pos, p[2], h, n, len) || p[3] == 0xff) {
      fprintf(stderr, "nfcbundle: warning: %s: .eh_frame_hdr has no search table; its code cannot be unwound\n", u->path.c_str());
      continue;
    }
    pos += len;
    for (uint64_t k = 0; k < n; k++) {
      uint64_t loc, fde;
      read_enc(u, pos, p[3], h, loc, len);
      pos += len;
      read_enc(u, pos, p[3], h, fde, len);
      pos += len;
      fdes.push_back({u, loc, fde});
    }
  }
  uint64_t ehhdr_size = fdes.empty() ? 0 : 16 + fdes.size() * 8;  // room for an 8-byte eh_frame_ptr
  // The unwinder's binary search takes only 32-bit offsets from the .eh_frame_hdr (DW_EH_PE_datarel|sdata4), so the
  // header has to be within 2 GiB of every FDE and function. At the end of the output (the new segment) it is,
  // unless the units span more than that (libtorch_cuda alone is 1.6 GB); then it gets a segment of its own in a gap
  // at the unit boundary nearest the middle, which works for up to 4 GiB.
  size_t ehgap = 0;  // the unit the header's own segment goes before (0: in the new segment)
  uint64_t ehgap_va = 0, va = 0;
  auto layout = [&](size_t gap) {
    va = align_up(mainobj->hi, PAGE);
    for (size_t k = 1; k < units.size(); k++) {
      Obj *u = units[k];
      if (k == gap) {
        ehgap_va = va;
        va = align_up(va + ehhdr_size, PAGE);
      }
      uint64_t al = PAGE;
      for (const Elf64_Phdr &p : u->ph)
        if (p.p_type == PT_LOAD) al = std::max<uint64_t>(al, p.p_align);
      u->base = align_up(va, al) - u->lo;
      va = align_up(u->base + u->hi, PAGE);
    }
  };
  layout(0);
  const int64_t reach = INT32_MAX - (int64_t)ehhdr_size - 2 * (int64_t)PAGE;
  auto lowest = (int64_t)mainobj->lo;
  if (ehhdr_size && (int64_t)va + (int64_t)PAGE * 2 + (1 << 20) - lowest > reach) {
    size_t best = 0;
    uint64_t best_far = UINT64_MAX;
    for (size_t k = 1; k < units.size(); k++) {
      layout(k);
      uint64_t far = std::max<uint64_t>(ehgap_va - lowest, va - ehgap_va);
      if (far < best_far) best_far = far, best = k;
    }
    if (best_far > (uint64_t)reach) die("the bundled libraries span more than 4 GiB: one .eh_frame_hdr cannot reach them all");
    ehgap = best;
    layout(ehgap);
    note(".eh_frame_hdr in its own segment at " + hex(ehgap_va) + ", before " + units[ehgap]->soname);
  }
  for (Obj *u : units)
    if (!u->is_main) note(u->soname + " at " + hex(u->base));
  for (FdeEnt &f : fdes) f.loc += f.u->base, f.fde += f.u->base;
  if (eh_frame_unit) eh_frame_va += eh_frame_unit->base;

  // TLS: one block, the libraries' first and the input's last (see the header comment).
  for (Obj *u : units)
    if (!u->is_main && u->tls) merge_tls = true;
  uint64_t tls_memsz = 0, tls_filesz = 0, tls_align = 1;
  if (merge_tls) {
    for (Obj *u : units)
      if (u->tls) tls_align = std::max<uint64_t>(tls_align, std::max<uint64_t>(u->tls->p_align, 1));
    uint64_t off = 0;
    for (Obj *u : units)
      if (!u->is_main && u->tls) {
        off = align_up(off, std::max<uint64_t>(u->tls->p_align, 1));
        u->tls_off = off;
        off += u->tls->p_memsz;
      }
    if (mainobj->tls) {
      uint64_t rm = align_up(mainobj->tls->p_memsz, std::max<uint64_t>(mainobj->tls->p_align, 1));
      uint64_t x = align_up(off + rm, tls_align);
      mainobj->tls_off = x - rm;
      tls_memsz = x;
    } else {
      tls_memsz = off;
    }
    for (Obj *u : units)
      if (u->tls && u->tls->p_filesz) tls_filesz = std::max(tls_filesz, u->tls_off + u->tls->p_filesz);
    for (Obj *u : units)
      if (u->tls) note(u->soname + ": TLS block at offset " + hex(u->tls_off) + " of " + hex(tls_memsz));
  }

  // The new segment: TLS image, .eh_frame_hdr, init/fini arrays, program headers, then the tables whose size the
  // relocation pass decides.
  uint64_t meta_va = va;
  uint64_t cur = meta_va;
  if (merge_tls) {
    cur = align_up(cur, tls_align);
    tls_image_va = cur;
    cur += tls_filesz;
  }
  std::sort(fdes.begin(), fdes.end(), [](const FdeEnt &a, const FdeEnt &b) { return a.loc < b.loc; });
  uint64_t ehhdr_va = 0, ehhdr_off = 0;
  if (!fdes.empty() && ehgap) {
    ehhdr_va = ehgap_va;
  } else if (!fdes.empty()) {
    cur = align_up(cur, 4);
    ehhdr_va = cur;
    cur += ehhdr_size;
  }
  // Init and fini entries: (unit, slot address) for an array entry, (unit, function) for DT_INIT / DT_FINI.
  struct ArrEnt {
    Obj *u;
    uint64_t slot, func;
  };
  std::vector<Obj *> order;  // dependencies first (post order over the bundled libraries)
  {
    std::set<Obj *> seen;
    std::vector<std::pair<Obj *, size_t>> st{{mainobj, 0}};
    seen.insert(mainobj);
    while (!st.empty()) {
      auto &[o, k] = st.back();
      if (k < o->deps.size()) {
        Obj *d = o->deps[k++];
        if (d->bundled && seen.insert(d).second) st.push_back({d, 0});
      } else {
        order.push_back(o);
        st.pop_back();
      }
    }
  }
  std::vector<ArrEnt> inits, finis;
  for (Obj *u : order) {
    if (u->init) inits.push_back({u, 0, u->init});
    for (uint64_t s = 0; s + 8 <= u->init_arraysz; s += 8) inits.push_back({u, u->init_array + s, 0});
  }
  // ld.so runs a fini array from the last entry to the first: the input's run first, each library's after the
  // libraries that need it, DT_FINI after its unit's array.
  for (Obj *u : order) {
    if (u->fini) finis.push_back({u, 0, u->fini});
    for (uint64_t s = 0; s + 8 <= u->fini_arraysz; s += 8) finis.push_back({u, u->fini_array + s, 0});
  }
  cur = align_up(cur, 8);
  uint64_t init_va = cur;
  cur += inits.size() * 8;
  uint64_t fini_va = cur;
  cur += finis.size() * 8;

  // Program headers of the output.
  std::vector<Elf64_Phdr> oph;
  Elf64_Phdr pt_phdr{}, pt_dynamic{}, pt_meta{};
  pt_phdr.p_type = PT_PHDR;
  pt_phdr.p_flags = PF_R;
  pt_phdr.p_align = 8;
  oph.push_back(pt_phdr);
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_INTERP) oph.push_back(p);
  std::map<size_t, std::string> load_owner;  // output PT_LOAD -> the unit it came from (section names)
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_LOAD) {
      load_owner[oph.size()] = mainobj->soname;
      oph.push_back(p);
    }
  uint64_t file_cur = align_up(main_end, 16);
  struct LibSeg {
    Obj *u;
    const Elf64_Phdr *p;
    uint64_t off;
  };
  std::vector<LibSeg> libsegs;
  for (Obj *u : units) {
    if (u->is_main) continue;
    if (ehgap && u == units[ehgap]) {
      Elf64_Phdr q{};
      q.p_type = PT_LOAD;
      q.p_flags = PF_R;
      q.p_vaddr = q.p_paddr = ehhdr_va;
      q.p_offset = ehhdr_off = file_cur + ((ehhdr_va - file_cur) & (PAGE - 1));
      q.p_filesz = q.p_memsz = ehhdr_size;
      q.p_align = PAGE;
      file_cur = q.p_offset + q.p_filesz;
      load_owner[oph.size()] = "eh_frame_hdr";
      oph.push_back(q);
    }
    for (const Elf64_Phdr &p : u->ph) {
      if (p.p_type != PT_LOAD) continue;
      Elf64_Phdr q = p;
      q.p_vaddr += u->base;
      q.p_paddr = q.p_vaddr;
      q.p_offset = file_cur + ((q.p_vaddr - file_cur) & (PAGE - 1));
      q.p_align = PAGE;
      file_cur = q.p_offset + q.p_filesz;
      libsegs.push_back({u, &p, q.p_offset});
      load_owner[oph.size()] = u->soname;
      oph.push_back(q);
    }
  }
  size_t meta_load_index = oph.size();
  pt_meta.p_type = PT_LOAD;
  pt_meta.p_flags = PF_R | PF_W;
  pt_meta.p_align = PAGE;
  oph.push_back(pt_meta);
  pt_dynamic.p_type = PT_DYNAMIC;
  pt_dynamic.p_flags = PF_R | PF_W;
  pt_dynamic.p_align = 8;
  size_t dynamic_index = oph.size();
  oph.push_back(pt_dynamic);
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_NOTE || p.p_type == PT_GNU_RELRO) oph.push_back(p);
  bool execstack = false;
  for (Obj *u : units)
    if (u->stack && (u->stack->p_flags & PF_X)) execstack = true;
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_GNU_STACK) {
      oph.push_back(p);
      if (execstack) oph.back().p_flags |= PF_X;
    }
  if (!merge_tls) {
    for (const Elf64_Phdr &p : mph)
      if (p.p_type == PT_TLS) oph.push_back(p);
  } else {
    Elf64_Phdr t{};
    t.p_type = PT_TLS;
    t.p_flags = PF_R;
    t.p_vaddr = t.p_paddr = tls_image_va;
    t.p_filesz = tls_filesz;
    t.p_memsz = tls_memsz;
    t.p_align = tls_align;
    oph.push_back(t);
  }
  if (ehhdr_va) {
    Elf64_Phdr e{};
    e.p_type = PT_GNU_EH_FRAME;
    e.p_flags = PF_R;
    e.p_vaddr = e.p_paddr = ehhdr_va;
    e.p_filesz = e.p_memsz = ehhdr_size;
    e.p_align = 4;
    oph.push_back(e);
  }
  uint64_t phdr_va = cur;
  cur += oph.size() * sizeof(Elf64_Phdr);

  // Exported symbols: the input's definitions with their versions, then (--export=all) the bundled libraries'. The
  // undefined symbols that the relocations need come after them. The input's version definitions keep their indices;
  // version needs are numbered after them.
  for (auto &[k, v] : mainobj->verdef) next_ver = std::max<uint16_t>(next_ver, k + 1);
  for (Obj *u : units) {
    if (!u->is_main && !export_all) break;
    for (size_t i = 1; i < u->nsyms; i++) {
      const Elf64_Sym &s = u->syms[i];
      if (!u->defined(i)) continue;
      int bind = ELF64_ST_BIND(s.st_info), vis = ELF64_ST_VISIBILITY(s.st_other);
      uint16_t ver = 1;
      if (u->is_main) {
        if (u->versym) ver = u->versym[i];
        // A definition made by a copy relocation has the index of a version it needs: numbered anew.
        if ((ver & 0x7fff) >= 2 && !u->verdef.count(ver & 0x7fff)) {
          auto it = u->verneed.find(ver & 0x7fff);
          bool gone = it == u->verneed.end();
          for (auto &o : objs)
            if (!gone && o->bundled && o->soname == it->second.file) gone = true;
          ver = gone ? 1 : need_version(it->second.file, it->second.name, it->second.flags);
        }
      } else {
        if (bind == STB_LOCAL || vis == STV_HIDDEN || vis == STV_INTERNAL) continue;
        if (u->versym && (u->versym[i] & 0x8000)) continue;  // a non-default version: the default one is exported
        if (ELF64_ST_TYPE(s.st_info) == STT_SECTION || ELF64_ST_TYPE(s.st_info) == STT_FILE) continue;
        if (exported.count(u->symname(i))) continue;
      }
      exported.insert(u->symname(i));
      export_of[{u, i}] = osyms.size();
      Elf64_Sym o = s;
      o.st_name = dynstr.add(u->symname(i));
      if (s.st_shndx != SHN_ABS) o.st_value = sym_value({u, i, false});
      osyms.push_back(o);
      oversym.push_back(ver);
    }
  }

  // Relocations of every unit.
  for (Obj *u : units)
    for (const Elf64_Rela &r : u->rel) translate(u, r, out_addr(u, r.r_offset));
  auto arr_rel = [&](const ArrEnt &e, uint64_t off) {
    if (e.func) {
      rel_relative.push_back({off, R_X86_64_RELATIVE, 0, (int64_t)(e.func + e.u->base)});
      return;
    }
    auto it = e.u->rel_at.find(e.slot);
    if (it != e.u->rel_at.end()) translate(e.u, e.u->rel[it->second], off);
    else rel_relative.push_back({off, R_X86_64_RELATIVE, 0, (int64_t)(e.u->rd64(e.slot) + e.u->base)});
  };
  for (size_t i = 0; i < inits.size(); i++) arr_rel(inits[i], init_va + i * 8);
  for (size_t i = 0; i < finis.size(); i++) arr_rel(finis[i], fini_va + i * 8);
  // A bundled copy source: its relocations are repeated at the copy.
  for (const Copy &c : copies)
    for (auto *list : {&rel_relative, &rel_other, &rel_irel}) {
      size_t n = list->size();
      for (size_t i = 0; i < n; i++)
        if ((*list)[i].off >= c.src && (*list)[i].off < c.src + c.size) {
          ORel r = (*list)[i];
          r.off += c.dst - c.src;
          list->push_back(r);
        }
    }

  bool versions = !mainobj->verdef.empty() || !oneed.empty();

  // Dynamic section entries; sizes of the remaining tables.
  std::vector<std::string> needed_out;
  for (auto &o : objs)
    if (!o->bundled) needed_out.push_back(o->soname);
  for (const std::string &n : missing) needed_out.push_back(n);
  // A version needed from a file that is not loaded directly is still needed: that file must be a DT_NEEDED.
  for (NeedOut &n : oneed)
    if (std::find(needed_out.begin(), needed_out.end(), n.file) == needed_out.end()) needed_out.push_back(n.file);
  // --stubs: the output needs its own stubs, so they are loaded from the start; ld.so then finds a plugin's DT_NEEDED
  // among the loaded objects by soname before it searches any path (the plugin's own DT_RUNPATH included).
  if (!opt_stubs.empty())
    for (Obj *u : units)
      if (!u->is_main && stubbable(u)) needed_out.push_back(u->needed_as);
  std::vector<uint32_t> needed_str;
  for (const std::string &n : needed_out) needed_str.push_back(dynstr.add(n));
  int64_t soname_str = mainobj->has_soname ? (int64_t)dynstr.add(mainobj->soname) : -1;
  // Search paths: the input's, then each bundled library's with $ORIGIN made absolute (the output may move).
  std::vector<std::string> paths;
  for (Obj *u : units) {
    std::string list = u->has_runpath ? u->runpath : u->rpath;
    for (const std::string &d : split(list, ':')) {
      std::string e = u->is_main ? d : expand_origin(d, u);
      if (std::find(paths.begin(), paths.end(), e) == paths.end()) paths.push_back(e);
    }
  }
  if (!opt_stubs.empty()) paths.insert(paths.begin(), stubs_path(opt_stubs, out));
  std::string pathlist;
  for (const std::string &p : paths) pathlist += (pathlist.empty() ? "" : ":") + p;
  if (runpath_set) {
    pathlist = opt_runpath;
    std::string sp = opt_stubs.empty() ? "" : stubs_path(opt_stubs, out);
    std::vector<std::string> given = split(opt_runpath, ':');
    if (!sp.empty() && std::find(given.begin(), given.end(), sp) == given.end()) pathlist = sp + (pathlist.empty() ? "" : ":" + pathlist);
  }
  int64_t path_str = pathlist.empty() ? -1 : (int64_t)dynstr.add(pathlist);
  // Version definitions of the input, re-encoded with names in the new string table.
  std::vector<uint8_t> verdef_bytes;
  int verdef_count = 0;
  for (uint64_t vaa = mainobj->verdef_va, i = 0; vaa && i < mainobj->verdefnum; i++) {
    Elf64_Verdef vd;
    memcpy(&vd, mainobj->at(vaa, sizeof vd), sizeof vd);
    size_t at = verdef_bytes.size();
    Elf64_Verdef nvd = vd;
    nvd.vd_aux = sizeof(Elf64_Verdef);
    std::vector<Elf64_Verdaux> aux;
    uint64_t a = vaa + vd.vd_aux;
    for (int j = 0; j < vd.vd_cnt; j++) {
      Elf64_Verdaux x;
      memcpy(&x, mainobj->at(a, sizeof x), sizeof x);
      Elf64_Verdaux y{dynstr.add(mainobj->str(x.vda_name)), 0};
      aux.push_back(y);
      if (!x.vda_next) break;
      a += x.vda_next;
    }
    nvd.vd_cnt = aux.size();
    bool last = !vd.vd_next || i + 1 == mainobj->verdefnum;
    nvd.vd_next = last ? 0 : sizeof(Elf64_Verdef) + aux.size() * sizeof(Elf64_Verdaux);
    put(verdef_bytes, at, nvd);
    for (size_t j = 0; j < aux.size(); j++) {
      aux[j].vda_next = j + 1 < aux.size() ? sizeof(Elf64_Verdaux) : 0;
      put(verdef_bytes, at + sizeof(Elf64_Verdef) + j * sizeof(Elf64_Verdaux), aux[j]);
    }
    verdef_count++;
    if (last) break;
    vaa += vd.vd_next;
  }
  std::vector<uint8_t> verneed_bytes;
  for (size_t i = 0; i < oneed.size(); i++) {
    NeedOut &n = oneed[i];
    size_t at = verneed_bytes.size();
    Elf64_Verneed vn{};
    vn.vn_version = VER_NEED_CURRENT;
    vn.vn_cnt = n.vers.size();
    vn.vn_file = dynstr.add(n.file);
    vn.vn_aux = sizeof(Elf64_Verneed);
    vn.vn_next = i + 1 < oneed.size() ? sizeof(Elf64_Verneed) + n.vers.size() * sizeof(Elf64_Vernaux) : 0;
    put(verneed_bytes, at, vn);
    for (size_t j = 0; j < n.vers.size(); j++) {
      Elf64_Vernaux x{};
      x.vna_hash = elf_hash(n.vers[j].first.c_str());
      x.vna_flags = n.vers[j].second;
      x.vna_other = n.idx[j];
      x.vna_name = dynstr.add(n.vers[j].first);
      x.vna_next = j + 1 < n.vers.size() ? sizeof(Elf64_Vernaux) : 0;
      put(verneed_bytes, at + sizeof(Elf64_Verneed) + j * sizeof(Elf64_Vernaux), x);
    }
  }
  // DT_HASH over all symbols.
  uint32_t nsym = osyms.size(), nbucket = std::max<uint32_t>(1, nsym / 2 + 1);
  std::vector<uint32_t> hashtab(2 + nbucket + nsym, 0);
  hashtab[0] = nbucket;
  hashtab[1] = nsym;
  for (uint32_t i = 1; i < nsym; i++) {
    uint32_t h = elf_hash(dynstr.data.c_str() + osyms[i].st_name) % nbucket;
    hashtab[2 + nbucket + i] = hashtab[2 + h];
    hashtab[2 + h] = i;
  }
  // Relocations, RELATIVE first (DT_RELACOUNT), IRELATIVE last (their resolvers may read other relocated data).
  std::vector<ORel> allrel = rel_relative;
  allrel.insert(allrel.end(), rel_other.begin(), rel_other.end());
  allrel.insert(allrel.end(), rel_irel.begin(), rel_irel.end());

  cur = align_up(cur, 8);
  uint64_t dyn_va = cur;
  size_t ndyn = needed_str.size() + 40;
  cur += ndyn * sizeof(Elf64_Dyn);
  uint64_t sym_va = cur;
  cur += osyms.size() * sizeof(Elf64_Sym);
  uint64_t rela_va = cur;
  cur += allrel.size() * sizeof(Elf64_Rela);
  uint64_t hash_va = cur;
  cur += hashtab.size() * 4;
  cur = align_up(cur, 8);
  uint64_t verdef_va = cur;
  cur += verdef_bytes.size();
  cur = align_up(cur, 8);
  uint64_t verneed_va = cur;
  cur += verneed_bytes.size();
  uint64_t versym_va = cur;
  cur += oversym.size() * 2;
  uint64_t str_va = cur;
  cur += dynstr.data.size();
  uint64_t meta_end = align_up(cur, 8);

  // File offsets: the new segment keeps the input's first-segment address-to-offset difference, so that an older
  // kernel, which takes AT_PHDR as that difference plus e_phoff, finds these program headers.
  uint64_t d0 = 0;
  for (const Elf64_Phdr &p : mph)
    if (p.p_type == PT_LOAD) {
      d0 = p.p_vaddr - p.p_offset;
      break;
    }
  uint64_t meta_off = meta_va - d0;
  if (meta_va < d0 || meta_off < file_cur) meta_off = file_cur + ((meta_va - file_cur) & (PAGE - 1));
  auto meta = [&](uint64_t v) { return v - meta_va; };
  std::vector<uint8_t> mb(meta_end - meta_va, 0);

  // Section headers, for the tools that read them (ld linking against an output shared object, nm -D, objdump, gdb):
  // one section per unit segment (<soname>.r / .rx / .rw, its bss part <soname>.bss), the TLS image, and the tables
  // of the new segment under their usual names. They go after the new segment in the file, outside every PT_LOAD.
  std::vector<Elf64_Shdr> sh(1);
  StrTab shstr;
  auto sec = [&](const std::string &name, uint32_t type, uint64_t flags, uint64_t addr, uint64_t off, uint64_t size,
                 uint32_t link = 0, uint32_t info = 0, uint64_t align = 1, uint64_t entsize = 0) {
    Elf64_Shdr x{};
    x.sh_name = shstr.add(name);
    x.sh_type = type;
    x.sh_flags = flags;
    x.sh_addr = addr;
    x.sh_offset = off;
    x.sh_size = size;
    x.sh_link = link;
    x.sh_info = info;
    x.sh_addralign = align;
    x.sh_entsize = entsize;
    sh.push_back(x);
    return (uint32_t)sh.size() - 1;
  };
  for (size_t i = 0; i < oph.size(); i++) {
    const Elf64_Phdr &p = oph[i];
    if (p.p_type != PT_LOAD || i == meta_load_index || load_owner[i] == "eh_frame_hdr") continue;
    std::string n = load_owner[i] + (p.p_flags & PF_X ? ".rx" : p.p_flags & PF_W ? ".rw" : ".r");
    uint64_t fl = SHF_ALLOC | (p.p_flags & PF_X ? SHF_EXECINSTR : 0) | (p.p_flags & PF_W ? SHF_WRITE : 0);
    if (p.p_filesz) sec(n, SHT_PROGBITS, fl, p.p_vaddr, p.p_offset, p.p_filesz, 0, 0, 16);
    if (p.p_memsz > p.p_filesz)
      sec(load_owner[i] + ".bss", SHT_NOBITS, fl, p.p_vaddr + p.p_filesz, p.p_offset + p.p_filesz, p.p_memsz - p.p_filesz, 0, 0, 16);
  }
  uint32_t tls_sec = 0;
  {
    const Elf64_Phdr *t = nullptr;
    for (const Elf64_Phdr &p : oph)
      if (p.p_type == PT_TLS) t = &p;
    uint64_t tva = merge_tls ? tls_image_va : t ? t->p_vaddr : 0;
    uint64_t toff = merge_tls ? meta_off + meta(tls_image_va) : t ? t->p_offset : 0;
    uint64_t tal = merge_tls ? tls_align : t ? t->p_align : 1;
    uint64_t tf = merge_tls ? tls_filesz : t ? t->p_filesz : 0, tm = merge_tls ? tls_memsz : t ? t->p_memsz : 0;
    if (tm) {
      // In the input's own segment when its PT_TLS is kept: the sections overlap theirs, which readers accept.
      if (tf) tls_sec = sec(".tdata", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE | SHF_TLS, tva, toff, tf, 0, 0, tal);
      if (tm > tf) {
        uint32_t b = sec(".tbss", SHT_NOBITS, SHF_ALLOC | SHF_WRITE | SHF_TLS, tva + tf, toff + tf, tm - tf, 0, 0, tal);
        if (!tls_sec) tls_sec = b;
      }
    }
  }
  uint32_t dynstr_sec = sec(".dynstr", SHT_STRTAB, SHF_ALLOC, str_va, meta_off + meta(str_va), dynstr.data.size());
  uint32_t dynsym_sec = sec(".dynsym", SHT_DYNSYM, SHF_ALLOC, sym_va, meta_off + meta(sym_va),
                            osyms.size() * sizeof(Elf64_Sym), dynstr_sec, 1, 8, sizeof(Elf64_Sym));
  sec(".hash", SHT_HASH, SHF_ALLOC, hash_va, meta_off + meta(hash_va), hashtab.size() * 4, dynsym_sec, 0, 8, 4);
  if (versions) {
    sec(".gnu.version", SHT_GNU_versym, SHF_ALLOC, versym_va, meta_off + meta(versym_va), oversym.size() * 2, dynsym_sec, 0, 2, 2);
    if (verdef_count)
      sec(".gnu.version_d", SHT_GNU_verdef, SHF_ALLOC, verdef_va, meta_off + meta(verdef_va), verdef_bytes.size(), dynstr_sec, verdef_count, 8);
    if (!oneed.empty())
      sec(".gnu.version_r", SHT_GNU_verneed, SHF_ALLOC, verneed_va, meta_off + meta(verneed_va), verneed_bytes.size(), dynstr_sec, oneed.size(), 8);
  }
  if (!allrel.empty())
    sec(".rela.dyn", SHT_RELA, SHF_ALLOC, rela_va, meta_off + meta(rela_va), allrel.size() * sizeof(Elf64_Rela), dynsym_sec, 0, 8, sizeof(Elf64_Rela));
  if (!inits.empty())
    sec(".init_array", SHT_INIT_ARRAY, SHF_ALLOC | SHF_WRITE, init_va, meta_off + meta(init_va), inits.size() * 8, 0, 0, 8, 8);
  if (!finis.empty())
    sec(".fini_array", SHT_FINI_ARRAY, SHF_ALLOC | SHF_WRITE, fini_va, meta_off + meta(fini_va), finis.size() * 8, 0, 0, 8, 8);
  if (ehhdr_va)
    sec(".eh_frame_hdr", SHT_PROGBITS, SHF_ALLOC, ehhdr_va, ehgap ? ehhdr_off : meta_off + meta(ehhdr_va), ehhdr_size, 0, 0, 4);
  sec(".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, dyn_va, meta_off + meta(dyn_va), ndyn * sizeof(Elf64_Dyn), dynstr_sec, 0, 8, sizeof(Elf64_Dyn));
  uint32_t shstr_sec = sec(".shstrtab", SHT_STRTAB, 0, 0, 0, 0);
  sh[shstr_sec].sh_name = shstr.add(".shstrtab");
  sh[shstr_sec].sh_offset = meta_off + mb.size();
  sh[shstr_sec].sh_size = shstr.data.size();
  uint64_t shoff = align_up(sh[shstr_sec].sh_offset + shstr.data.size(), 8);
  // The defined symbols' section indices: the output section that holds the address (the TLS section for TLS).
  for (size_t i = 1; i < osyms.size(); i++) {
    Elf64_Sym &o = osyms[i];
    if (o.st_shndx == SHN_UNDEF || o.st_shndx >= SHN_LORESERVE) continue;
    if (ELF64_ST_TYPE(o.st_info) == STT_TLS) {
      o.st_shndx = tls_sec ? tls_sec : SHN_ABS;
      continue;
    }
    uint32_t best = 0;
    for (uint32_t k = 1; k < sh.size(); k++)
      if ((sh[k].sh_flags & SHF_ALLOC) && !(sh[k].sh_flags & SHF_TLS) && o.st_value >= sh[k].sh_addr &&
          o.st_value <= sh[k].sh_addr + sh[k].sh_size && (!best || sh[k].sh_addr >= sh[best].sh_addr))
        best = k;
    o.st_shndx = best ? best : SHN_ABS;
  }

  // Dynamic section.
  std::vector<Elf64_Dyn> dyn;
  auto dt = [&](int64_t tag, uint64_t v) { dyn.push_back({tag, {v}}); };
  for (uint32_t s : needed_str) dt(DT_NEEDED, s);
  if (soname_str >= 0) dt(DT_SONAME, soname_str);
  if (path_str >= 0) dt((runpath_set ? rpath_kind : mainobj->has_rpath && !mainobj->has_runpath) ? DT_RPATH : DT_RUNPATH, path_str);
  dt(DT_HASH, hash_va);
  dt(DT_STRTAB, str_va);
  dt(DT_SYMTAB, sym_va);
  dt(DT_STRSZ, dynstr.data.size());
  dt(DT_SYMENT, sizeof(Elf64_Sym));
  if (!allrel.empty()) {
    dt(DT_RELA, rela_va);
    dt(DT_RELASZ, allrel.size() * sizeof(Elf64_Rela));
    dt(DT_RELAENT, sizeof(Elf64_Rela));
    dt(DT_RELACOUNT, rel_relative.size());
  }
  if (!inits.empty()) {
    dt(DT_INIT_ARRAY, init_va);
    dt(DT_INIT_ARRAYSZ, inits.size() * 8);
  }
  if (!finis.empty()) {
    dt(DT_FINI_ARRAY, fini_va);
    dt(DT_FINI_ARRAYSZ, finis.size() * 8);
  }
  for (uint64_t vaa = mainobj->dynamic->p_vaddr;; vaa += 16) {
    Elf64_Dyn e;
    memcpy(&e, mainobj->at(vaa, 16), 16);
    if (e.d_tag == DT_NULL) break;
    if (e.d_tag == DT_PREINIT_ARRAY || e.d_tag == DT_PREINIT_ARRAYSZ) dyn.push_back(e);
  }
  if (versions) {
    dt(DT_VERSYM, versym_va);
    if (verdef_count) {
      dt(DT_VERDEF, verdef_va);
      dt(DT_VERDEFNUM, verdef_count);
    }
    if (!oneed.empty()) {
      dt(DT_VERNEED, verneed_va);
      dt(DT_VERNEEDNUM, oneed.size());
    }
  }
  bool textrel = false;
  for (Obj *u : units) {
    textrel |= u->textrel;
    if (u->flags & DF_STATIC_TLS) static_tls = true;
  }
  uint64_t flags = DF_BIND_NOW | (textrel ? DF_TEXTREL : 0) | (static_tls ? DF_STATIC_TLS : 0) | (mainobj->flags & DF_ORIGIN);
  dt(DT_FLAGS, flags);
  dt(DT_FLAGS_1, (mainobj->flags_1 | DF_1_NOW) & ~(uint64_t)DF_1_NODEFLIB);
  if (textrel) dt(DT_TEXTREL, 0);
  if (mainobj->has_debug) dt(DT_DEBUG, 0);
  if (dyn.size() + 1 > ndyn) die("internal error: dynamic section overflow");
  while (dyn.size() < ndyn) dyn.push_back({DT_NULL, {0}});
  put(mb, meta(dyn_va), dyn.data(), dyn.size() * sizeof(Elf64_Dyn));
  put(mb, meta(sym_va), osyms.data(), osyms.size() * sizeof(Elf64_Sym));
  for (size_t i = 0; i < allrel.size(); i++) {
    Elf64_Rela r{allrel[i].off, ELF64_R_INFO(allrel[i].sym, allrel[i].type), allrel[i].addend};
    put(mb, meta(rela_va) + i * sizeof r, r);
  }
  put(mb, meta(hash_va), hashtab.data(), hashtab.size() * 4);
  if (!verdef_bytes.empty()) put(mb, meta(verdef_va), verdef_bytes.data(), verdef_bytes.size());
  if (!verneed_bytes.empty()) put(mb, meta(verneed_va), verneed_bytes.data(), verneed_bytes.size());
  put(mb, meta(versym_va), oversym.data(), oversym.size() * 2);
  put(mb, meta(str_va), dynstr.data.data(), dynstr.data.size());
  // TLS image.
  if (merge_tls)
    for (Obj *u : units)
      if (u->tls && u->tls->p_filesz) {
        if (u->tls->p_offset + u->tls->p_filesz > u->d.size()) die(u->path + ": PT_TLS outside the file");
        put(mb, meta(tls_image_va) + u->tls_off, u->d.data() + u->tls->p_offset, u->tls->p_filesz);
      }
  // .eh_frame_hdr.
  // .eh_frame_hdr: version 1, eh_frame_ptr pcrel|sdata4 (sdata8 when .eh_frame is farther), udata4 count, and the
  // datarel|sdata4 table the unwinder can binary search.
  std::vector<uint8_t> hb;
  if (ehhdr_va) {
    int64_t ptr = eh_frame_va ? (int64_t)eh_frame_va - (int64_t)(ehhdr_va + 4) : 0;
    bool near = ptr == (int32_t)ptr;
    uint8_t h4[4] = {1, (uint8_t)(near ? 0x1b : 0x1c), 0x03, 0x3b};
    put(hb, 0, h4, 4);
    if (near) put(hb, 4, (int32_t)ptr);
    else put(hb, 4, ptr);
    size_t t = near ? 8 : 12;
    put(hb, t, (uint32_t)fdes.size());
    for (size_t i = 0; i < fdes.size(); i++) {
      int64_t l = (int64_t)fdes[i].loc - (int64_t)ehhdr_va, f = (int64_t)fdes[i].fde - (int64_t)ehhdr_va;
      if (l != (int32_t)l || f != (int32_t)f) die("the merged .eh_frame_hdr does not reach every FDE");
      put(hb, t + 4 + i * 8, (int32_t)l);
      put(hb, t + 8 + i * 8, (int32_t)f);
    }
    if (hb.size() > ehhdr_size) die("internal error: .eh_frame_hdr size");
    if (!ehgap) put(mb, meta(ehhdr_va), hb.data(), hb.size());
  }

  // Program headers, now that the new segment's size is known.
  oph[0].p_offset = meta_off + meta(phdr_va);
  oph[0].p_vaddr = oph[0].p_paddr = phdr_va;
  oph[0].p_filesz = oph[0].p_memsz = oph.size() * sizeof(Elf64_Phdr);
  oph[meta_load_index].p_offset = meta_off;
  oph[meta_load_index].p_vaddr = oph[meta_load_index].p_paddr = meta_va;
  oph[meta_load_index].p_filesz = oph[meta_load_index].p_memsz = mb.size();
  oph[dynamic_index].p_offset = meta_off + meta(dyn_va);
  oph[dynamic_index].p_vaddr = oph[dynamic_index].p_paddr = dyn_va;
  oph[dynamic_index].p_filesz = oph[dynamic_index].p_memsz = ndyn * sizeof(Elf64_Dyn);
  for (Elf64_Phdr &p : oph) {
    if (p.p_type == PT_TLS && merge_tls) p.p_offset = meta_off + meta(tls_image_va);
    if (p.p_type == PT_GNU_EH_FRAME && ehhdr_va) p.p_offset = ehgap ? ehhdr_off : meta_off + meta(ehhdr_va);
  }
  put(mb, meta(phdr_va), oph.data(), oph.size() * sizeof(Elf64_Phdr));

  // The image below the new segment: the input, then the libraries' segments.
  std::vector<uint8_t> img(file_cur, 0);
  memcpy(img.data(), mainobj->d.data(), std::min<uint64_t>(main_end, mainobj->d.size()));
  if (materialize)  // the materialized bss: zeros, not whatever followed the segment in the input file
    for (const Elf64_Phdr &p : mainobj->ph)
      if (p.p_type == PT_LOAD && p.p_offset == last_load->p_offset)
        memset(img.data() + p.p_offset + p.p_filesz, 0, p.p_memsz - p.p_filesz);
  for (const LibSeg &s : libsegs) memcpy(img.data() + s.off, s.u->d.data() + s.p->p_offset, s.p->p_filesz);
  if (ehgap) memcpy(img.data() + ehhdr_off, hb.data(), hb.size());
  // Output address -> place in img or mb (file-backed bytes only).
  auto file_ptr = [&](uint64_t a, size_t n) -> uint8_t * {
    if (a >= meta_va && a + n <= meta_va + mb.size()) return mb.data() + (a - meta_va);
    for (const Elf64_Phdr &p : oph)
      if (p.p_type == PT_LOAD && &p != &oph[meta_load_index] && a >= p.p_vaddr && a + n <= p.p_vaddr + p.p_filesz)
        return img.data() + p.p_offset + (a - p.p_vaddr);
    return nullptr;
  };
  for (auto &[a, v] : patches) {
    uint8_t *p = file_ptr(a, 8);
    if (!p) die("cannot write a bound value at " + hex(a) + ": not in the file");
    memcpy(p, &v, 8);
  }
  for (auto &[a, v] : patches32) {
    uint8_t *p = file_ptr(a, 4);
    if (!p) die("cannot write a bound value at " + hex(a) + ": not in the file");
    memcpy(p, &v, 4);
  }
  for (const Copy &c : copies) {
    uint8_t *dst = file_ptr(c.dst, c.size);
    if (!dst) die("copy relocation destination " + hex(c.dst) + " is not in the file");
    for (uint64_t k = 0; k < c.size; k++) {
      uint8_t *s = file_ptr(c.src + k, 1);
      dst[k] = s ? *s : 0;
    }
  }
  // ELF header.
  Elf64_Ehdr eh = mainobj->eh;
  eh.e_phoff = meta_off + meta(phdr_va);
  eh.e_phnum = oph.size();
  eh.e_shoff = shoff;
  eh.e_shnum = sh.size();
  eh.e_shentsize = sizeof(Elf64_Shdr);
  eh.e_shstrndx = shstr_sec;
  memcpy(img.data(), &eh, sizeof eh);

  std::string tmp = out + ".tmp";
  FILE *f = fopen(tmp.c_str(), "wb");
  if (!f) die("cannot write " + tmp + ": " + strerror(errno));
  bool ok = fwrite(img.data(), 1, img.size(), f) == img.size() && fseek(f, meta_off, SEEK_SET) == 0 &&
            fwrite(mb.data(), 1, mb.size(), f) == mb.size() &&
            fwrite(shstr.data.data(), 1, shstr.data.size(), f) == shstr.data.size() &&
            fseek(f, shoff, SEEK_SET) == 0 && fwrite(sh.data(), sizeof(Elf64_Shdr), sh.size(), f) == sh.size();
  ok = fclose(f) == 0 && ok;
  if (!ok) die("cannot write " + tmp);
  chmod(tmp.c_str(), 0755);
  if (rename(tmp.c_str(), out.c_str()) != 0) die("cannot rename " + tmp + " to " + out + ": " + strerror(errno));
  if (!opt_stubs.empty()) {
    for (Obj *u : units)
      if (!u->is_main && stubbable(u)) write_stub(u, opt_stubs, mainobj->exe() ? "" : (mainobj->has_soname ? mainobj->soname : ""));
  }
  note("wrote " + out + ": " + std::to_string(units.size() - 1) + " libraries, " + std::to_string(allrel.size()) +
       " relocations, " + std::to_string(osyms.size() - 1) + " dynamic symbols");
  return 0;
}
