// nfceval implementation. See nfceval.hpp and docs/notes/eval.md. Finding the driver, hashing, the cache directory, running the
// driver and dlopen are in nfceval_build.hpp (shared with the tier of lib/ast).
#include "nfceval.hpp"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

#include "nfceval_build.hpp"

namespace nfceval {

namespace {

using build::file_exists;
using build::hash_hex;
using build::read_file;
using build::write_file;

bool is_ident(const std::string& s) {
  if (s.empty() || !(std::isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
  for (std::size_t i = 0; i < s.size(); ++i)
    if (!(std::isalnum((unsigned char)s[i]) || s[i] == '_')) return false;
  return true;
}

bool blank(const std::string& s, std::size_t from = 0, std::size_t to = std::string::npos) {
  if (to > s.size()) to = s.size();
  for (std::size_t i = from; i < to; ++i)
    if (!std::isspace((unsigned char)s[i])) return false;
  return true;
}

// What the snippet looks like: does it contain a `return` token, and where does the last top-level
// ';' end the final statement (npos: none). Strings, characters and comments are skipped.
struct Scan {
  bool has_return = false;
  std::size_t last_semi = std::string::npos;
};

Scan scan(const std::string& s) {
  Scan r;
  int depth = 0;
  for (std::size_t i = 0; i < s.size();) {
    char c = s[i];
    if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') {
      while (i < s.size() && s[i] != '\n') ++i;
    } else if (c == '/' && i + 1 < s.size() && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < s.size() && !(s[i] == '*' && s[i + 1] == '/')) ++i;
      i += 2;
    } else if (c == '"' || c == '\'') {
      ++i;
      while (i < s.size() && s[i] != c) i += (s[i] == '\\') ? 2 : 1;
      ++i;
    } else if (std::isalpha((unsigned char)c) || c == '_') {
      std::size_t b = i;
      while (i < s.size() && (std::isalnum((unsigned char)s[i]) || s[i] == '_')) ++i;
      if (s.compare(b, i - b, "return") == 0) r.has_return = true;
    } else {
      if (c == '(' || c == '[' || c == '{') ++depth;
      else if (c == ')' || c == ']' || c == '}') --depth;
      else if (c == ';' && depth == 0) r.last_semi = i;
      ++i;
    }
  }
  return r;
}

// The snippet as a function body. Line numbers are preserved (no newline is added before the end).
std::string wrap_body(const std::string& code, bool is_void) {
  Scan sc = scan(code);
  if (sc.has_return) return code;
  std::size_t from = sc.last_semi == std::string::npos ? 0 : sc.last_semi + 1;
  if (blank(code, from)) return code;  // ends with ';' (or is empty)
  // a trailing block statement ("if (c) { ... }") is not an expression
  std::size_t e = code.find_last_not_of(" \t\r\n");
  std::size_t b = code.find_first_not_of(" \t\r\n", from);
  if (code[e] == '}') return code;
  static const char* const kw[] = {"if", "for", "while", "switch", "do", "try", "{"};
  for (const char* k : kw) {
    std::size_t n = std::strlen(k);
    if (code.compare(b, n, k) == 0 && (n == 1 || b + n >= code.size() || !(std::isalnum((unsigned char)code[b + n]) || code[b + n] == '_')))
      return code;
  }
  if (is_void) return code + ";";
  return code.substr(0, from) + " return (" + code.substr(from) + "\n);";
}

bool unspellable(const std::string& t) {
  return t.empty() || t.find("lambda") != std::string::npos || t.find("<unnamed") != std::string::npos ||
         t.find("anonymous") != std::string::npos || t.find('{') != std::string::npos ||
         t.find("<unknown") != std::string::npos;
}

struct Loaded {
  void* handle;
  int (*entry)(void* const*, void*, char*, unsigned long);
};

}  // namespace

struct Engine::Impl {
#ifdef NFCEVAL_DEFAULT_DRIVER
  std::string driver = build::default_driver(__FILE__, NFCEVAL_DEFAULT_DRIVER);
#else
  std::string driver = build::default_driver(__FILE__);
#endif
  std::string cache;
  std::vector<std::string> flags;
  unsigned timeout = 300;
  std::string prelude;
  std::vector<detail::Slot> slots;
  std::map<std::string, Loaded> loaded;  // key -> handle
  unsigned compiles = 0, loads = 0;

  std::string cache_dir() {
    if (cache.empty()) cache = build::default_cache_dir("NFCEVAL_CACHE", "nfceval-cache");
    return cache;
  }

  void ensure_cache() {
    std::string err = build::ensure_cache_dir(cache_dir());
    if (!err.empty()) throw Error("nfceval: " + err);
  }

  Loaded load(const std::string& key, const std::string& src) {
    auto it = loaded.find(key);
    if (it != loaded.end()) return it->second;
    ensure_cache();
    std::string base = cache_dir() + "/nfceval-" + key;
    std::string so = base + ".so";
    if (!file_exists(so)) {
      std::string pid = std::to_string((long)::getpid());
      std::string cpp = base + ".cpp", tmp = base + "." + pid + ".so", log = base + "." + pid + ".log";
      if (!write_file(cpp, src)) throw Error("nfceval: cannot write " + cpp);
      std::vector<std::string> args;
      args.push_back(driver);
      args.push_back("-shared");
      for (const std::string& f : flags) args.push_back(f);
      args.push_back(cpp);
      args.push_back("-o");
      args.push_back(tmp);
      int status = 0;
      ++compiles;
      std::string out = build::run_driver(args, log, timeout, status);
      ::unlink(log.c_str());
      if (status != 0 || !file_exists(tmp)) {
        ::unlink(tmp.c_str());
        std::string why = build::failure_reason(status, driver, timeout);
        if (status == 127 || status == -2) throw Error("nfceval: " + why + "\n" + out);
        throw CompileError("nfceval: " + why + "\n" + out);
      }
      if (::rename(tmp.c_str(), so.c_str()) != 0) {
        ::unlink(tmp.c_str());
        throw Error("nfceval: cannot install " + so + ": " + std::strerror(errno));
      }
    }
    void* sym = nullptr;
    std::string err;
    void* h = build::open_so(so, "nfceval_entry", &sym, &err);
    if (!h) throw Error("nfceval: " + err);
    ++loads;
    Loaded l;
    l.handle = h;
    *reinterpret_cast<void**>(&l.entry) = sym;
    loaded[key] = l;
    return l;
  }

  std::string cache_key(const std::string& src) const {
    std::string k = src;
    k += "\n//driver:" + driver;
    for (const std::string& f : flags) k += "\n//flag:" + f;
    const char* be = std::getenv("NFCXX_BACKEND");
    k += std::string("\n//backend:") + (be ? be : "");
    return hash_hex(k);
  }
};

Engine::Engine() : p_(new Impl) {}

Engine::~Engine() {
  for (auto& kv : p_->loaded) ::dlclose(kv.second.handle);
}

Engine& Engine::set_driver(std::string path) {
  p_->driver = std::move(path);
  return *this;
}
Engine& Engine::set_cache_dir(std::string dir) {
  p_->cache = std::move(dir);
  return *this;
}
Engine& Engine::add_flag(std::string flag) {
  p_->flags.push_back(std::move(flag));
  return *this;
}
Engine& Engine::set_compile_timeout(unsigned seconds) {
  p_->timeout = seconds;
  return *this;
}
Engine& Engine::prelude(const std::string& code) {
  p_->prelude += code;
  p_->prelude += "\n";
  return *this;
}
Engine& Engine::include(const std::string& header) {
  if (!header.empty() && header[0] == '<') return prelude("#include " + header);
  return prelude("#include \"" + header + "\"");
}

static detail::Slot* find_slot(std::vector<detail::Slot>& v, const std::string& name) {
  for (detail::Slot& s : v)
    if (s.name == name) return &s;
  return nullptr;
}

static void put_slot(std::vector<detail::Slot>& v, detail::Slot s) {
  if (detail::Slot* old = find_slot(v, s.name)) *old = std::move(s);
  else v.push_back(std::move(s));
}

Engine& Engine::bind_ref(const std::string& name, const std::string& type, void* addr) {
  if (!is_ident(name)) throw Error("nfceval: '" + name + "' is not an identifier");
  if (unspellable(type))
    throw Error("nfceval: cannot spell the type of '" + name + "' (" + type + "); pass it as the third argument of bind()");
  detail::Slot s;
  s.name = name;
  s.decl = "typedef " + type + " nfceval_T_" + name + "; [[maybe_unused]] nfceval_T_" + name + "& " + name + " = *static_cast<nfceval_T_" + name +
           "*>(nfceval_t[@0]);";
  s.words.push_back(addr);
  put_slot(p_->slots, std::move(s));
  return *this;
}

Engine& Engine::bind_function(const std::string& name, const std::string& ret, const std::vector<std::string>& args,
                              void* thunk, void* state, std::unique_ptr<void, void (*)(void*)> keep) {
  if (!is_ident(name)) throw Error("nfceval: '" + name + "' is not an identifier");
  if (unspellable(ret)) throw Error("nfceval: cannot spell the return type of '" + name + "'");
  std::string params, call, ptrty = ret + " (*)(void*";
  for (std::size_t i = 0; i < args.size(); ++i) {
    if (unspellable(args[i])) throw Error("nfceval: cannot spell parameter " + std::to_string(i) + " of '" + name + "'");
    std::string n = "a" + std::to_string(i);
    params += (i ? ", " : "") + args[i] + " " + n;
    call += ", nfceval_fwd<" + args[i] + ">(" + n + ")";
    ptrty += ", " + args[i];
  }
  ptrty += ")";
  detail::Slot s;
  s.name = name;
  // fn: file-scope function (placed before the snippet function); @0/@1 are the table indices.
  s.decl = "@F [[maybe_unused]] static " + ret + " " + name + "(" + params + ") { return reinterpret_cast<" + ptrty + ">(nfceval_tbl_[@0])(nfceval_tbl_[@1]" +
           call + "); }";
  s.words.push_back(thunk);
  s.words.push_back(state);
  s.keep = std::move(keep);
  put_slot(p_->slots, std::move(s));
  return *this;
}

Engine& Engine::unbind(const std::string& name) {
  for (std::size_t i = 0; i < p_->slots.size(); ++i)
    if (p_->slots[i].name == name) {
      p_->slots.erase(p_->slots.begin() + i);
      break;
    }
  return *this;
}

static void replace_all(std::string& s, const std::string& from, const std::string& to) {
  for (std::size_t p = 0; (p = s.find(from, p)) != std::string::npos; p += to.size()) s.replace(p, from.size(), to);
}

std::string Engine::generate(const std::string& code, const std::string& r_type) const {
  bool is_void = r_type.empty();
  std::string fns, refs;
  std::size_t idx = 0;
  for (const detail::Slot& s : p_->slots) {
    std::string d = s.decl;
    bool is_fn = d.compare(0, 3, "@F ") == 0;
    if (is_fn) d = d.substr(3);
    replace_all(d, "@0", std::to_string(idx));
    replace_all(d, "@1", std::to_string(idx + 1));
    idx += s.words.size();
    (is_fn ? fns : refs) += d + "\n";
  }
  std::string o;
  o += "// generated by nfceval\n";
  o += "#include <new>\n#include <exception>\n#include <stdexcept>\n#include <string>\n#include <cstdio>\n"
       "#include <cstdlib>\n#include <cstring>\n#include <cmath>\n#include <type_traits>\n";
  o += p_->prelude;
  o += "static void* const* nfceval_tbl_;\n"
       "template <class T> T&& nfceval_fwd(typename std::remove_reference<T>::type& t) { return static_cast<T&&>(t); }\n";
  o += fns;
  if (!is_void) o += "typedef " + r_type + " nfceval_R;\n";
  o += is_void ? "static void nfceval_body(void* const* nfceval_t) {\n" : "static nfceval_R nfceval_body(void* const* nfceval_t) {\n";
  o += refs;
  o += "#line 1 \"snippet\"\n";
  o += wrap_body(code, is_void);
  o += "\n#line 1 \"nfceval-generated\"\n";
  // not reached when the snippet returns; the condition keeps the compiler from warning about unreachable code
  if (!is_void) o += "  if (nfceval_tbl_) throw std::runtime_error(\"snippet did not return a value\");\n  __builtin_unreachable();\n";
  o += "}\n";
  o += "static void nfceval_msg(char* d, unsigned long n, const char* m) {\n"
       "  if (n == 0) return;\n  std::strncpy(d, m, n - 1);\n  d[n - 1] = 0;\n}\n";
  o += "extern \"C\" int nfceval_entry(void* const* t, void* res, char* err, unsigned long errn) {\n"
       "  nfceval_tbl_ = t;\n  (void)res;\n  try {\n";
  o += is_void ? "    nfceval_body(t);\n" : "    ::new (res) nfceval_R(nfceval_body(t));\n";
  o += "    return 0;\n"
       "  } catch (const std::exception& e) {\n    nfceval_msg(err, errn, e.what());\n    return 1;\n"
       "  } catch (...) {\n    nfceval_msg(err, errn, \"unknown exception\");\n    return 1;\n  }\n}\n";
  return o;
}

void Engine::run(const std::string& code, const std::string& r_type, void* result) {
  std::string src = generate(code, r_type);
  Loaded l = p_->load(p_->cache_key(src), src);
  std::vector<void*> table;
  for (const detail::Slot& s : p_->slots)
    for (void* w : s.words) table.push_back(w);
  table.push_back(nullptr);
  char err[2048];
  err[0] = 0;
  if (l.entry(table.data(), result, err, sizeof err) != 0) throw RuntimeError(err);
}

unsigned Engine::compiles() const { return p_->compiles; }
unsigned Engine::loads() const { return p_->loads; }
const std::string& Engine::cache_dir() const {
  static thread_local std::string s;
  s = p_->cache_dir();
  return s;
}

}  // namespace nfceval
